# Phase 2 device, files, media, Git and capture design (P-001–P-013)

Status: Phase 2 draft aligned to the frozen root Phase 1 contracts

Baseline: `d152b118045264abeb8a1760b94113e323e46283`

Phase 1 alignment freeze: `2876926238d89dd63864081574508baf6ffe2a51`

Binding status: `FROZEN_BINDING` for SourcePartition, AuthenticatedExecutionContext, OperationKernel, ContentOffer/ContentRef/ContentAccessTicket and ComposerAttachmentRef

Default disposition: `KEEP_EFFECT / REUSE_EXISTING`

## 1. Scope and non-negotiable boundaries

This draft designs the product platform around the one Session Kernel. It does **not** create a Device Core, File Core, Product Core, Gallery Core, Git Core or Capture Core. Device routes, files, transfers, previews, gallery, Git and capture remain typed product services. They may consume Phase 1 identity, actor, execution-context, content-reference and readiness ports, but they do not own session identity, canonical history, timeline order, operation replay or provider truth.

No capability in P-001–P-013 writes a row into the Session Kernel timeline. Every authenticated Bridge-side mutation is nevertheless admitted, fingerprinted and tracked by the single `OperationKernel`; product services execute the typed domain effect after admission and return evidence for reconciliation. Mobile-local route preferences and pre-auth pairing bootstrap are not remote mutations and cannot change Bridge/provider truth. Only an explicit composer Send may produce a provider/session mutation, and even then the file subsystem contributes an immutable attachment/content reference rather than a timeline row or raw bytes.

The design is based on the local input lock, the v4 peripheral capsules/pressure matrices/core-touch candidates/current-to-target map, `docs/PROJECT_HANDOFF.md`, relevant `decisions.md` chapters, and the actual Bridge, Flutter, iOS native and test sources at the baseline above. Source presence is evidence of a current implementation surface, not proof of a deployed Bridge, signed IPA, entitlement, physical-device behavior or stable release.

### 1.1 Phase 1 binding vocabulary

| Mark | Meaning in this draft |
|---|---|
| `FROZEN_BINDING` | Bind directly to the root Phase 1 contract. This draft may add a product adapter but cannot fork, narrow or rename the authoritative semantics. |
| `FROZEN_BINDING` | Root decisions and Phase 1 machine sources own the contract; Phase 2 consumes it without adding authority or duplicate fields. |
| `NO_CORE_CHANGE` | The capability can be completed behind an existing product boundary. It may consume a frozen core interface without changing it. |
| `USE_EXISTING` | The frozen interface, once verified, is sufficient; implement only an adapter at the product boundary. |
| `AMEND` | Retained disposition vocabulary only; no current row requests a Phase 1 amendment. Any later pressure requires an explicit root contract revision and never authorizes a Phase 2 fork. |
| `NEW_MINIMAL` | A new typed contract is needed only inside Product Platform, control plane or content plane. It must remain feature-owned and cannot become a second core. |

### 1.2 Binding ledger

| Capability | Core-facing dependency | Decision | Product-side work |
|---|---|---|---|
| P-001 | `FROZEN_BINDING: SourcePartition / OperationKernel`; product-local Computer/ConnectionRoute | `NO_CORE_CHANGE / USE_EXISTING` | Adapt `Machine` and grouping; add explicit route ordering; route preferences remain local. |
| P-002 | `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel` | `NO_CORE_CHANGE / USE_EXISTING` | Adapt existing signed identity, pairing and connection-auth stores; pairing bootstrap is the pre-auth exception. |
| P-003 | `FROZEN_BINDING: AuthenticatedExecutionContext.source/sourceEpoch` | `NO_CORE_CHANGE / USE_EXISTING` | `NEW_MINIMAL` expiring discovery-candidate DTO; saved route remains existing product data. |
| P-004 | `FROZEN_BINDING: AuthenticatedExecutionContext.sourceEpoch`; product-local readiness snapshot | `NO_CORE_CHANGE / USE_EXISTING` | Reuse current Bridge readiness and Mobile progress/watchdog orchestration. |
| P-005 | `FROZEN_BINDING: AuthenticatedExecutionContext / ContentRef / ContentAccessTicket` | `NO_CORE_CHANGE / USE_EXISTING` | Add bounded search as a feature protocol; keep browser feature-owned. |
| P-006 | `FROZEN_BINDING: SourcePartition / AuthenticatedExecutionContext / OperationKernel / ContentOffer / ContentRef` | `NO_CORE_CHANGE / USE_EXISTING` | Keep transfer state machine; add ordinary-transfer digest manifest. |
| P-007 | `FROZEN_BINDING: OperationKernel / ContentRef / ComposerAttachmentRef` | `NO_CORE_CHANGE / USE_EXISTING` | Reuse drop/picker staging; only explicit Send enters OperationKernel. |
| P-008 | `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel` | `NO_CORE_CHANGE / USE_EXISTING` | Extend exact-operation proof as an OperationKernel precondition. |
| P-009 | `FROZEN_BINDING: AuthenticatedExecutionContext / ContentRef / ContentAccessTicket` | `NO_CORE_CHANGE / USE_EXISTING` | Keep Quick Look-first preview and bounded fallback. |
| P-010 | `FROZEN_BINDING: AuthenticatedExecutionContext / ContentRef / ContentAccessTicket` | `NO_CORE_CHANGE / USE_EXISTING` | Adapt current artifact registry and short lease to the frozen protocol names. |
| P-011 | `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel / ContentOffer / ContentRef` | `NO_CORE_CHANGE / USE_EXISTING` | Adapt existing gallery/image stores with auth, paging and retention. |
| P-012 | `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel` | `NO_CORE_CHANGE / USE_EXISTING` | Git reads remain product service; every Git mutation uses OperationKernel. |
| P-013 | `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel / ContentOffer / ContentRef` | `NO_CORE_CHANGE / USE_EXISTING` | Extend existing screenshot/event-recording product lifecycle. |

Phase 2 must use the frozen owners above exactly. `NEW_MINIMAL` remains limited to feature protocols and executors; it never creates a second identity, execution-context, mutation or operation-state owner.

## 2. Shared platform model

### 2.1 Identity layers

| Layer | Durable meaning | May change without data migration? | Never use as |
|---|---|---|---|
| Computer | User-visible grouping by `bridgeIdentityId` | No; signing-identity change creates a new/untrusted computer until user rebinds | IP address, display title, `bridgeInstanceId` or data partition |
| Route | How Mobile reaches that computer: LAN, Tailscale/DNS, manual, SSH/jump | Yes; routes are editable, sortable and removable | session/catalog/cache namespace |
| Bridge instance | One persistent Bridge installation/state namespace, owned only by `BridgeInstallationStore` | Route can change while this stays stable | signing identity, prompt-history ownership or route health |
| Codex source | Opaque persistent source ID created/owned by `SourceRegistry`; paths/config are only locators | A Bridge may expose a distinct source | computer identity, `CODEX_HOME` path or path hash |
| Connection generation | One authenticated socket/application-ready epoch | Always changes on reconnect/authority loss | durable object ID |
| Actor | Server-injected principal/assurance inside `AuthenticatedExecutionContext` | Changes on pairing/revocation/re-auth | a request field or client boolean such as `faceIdPassed` |

The frozen canonical partition is `SourcePartition = (bridgeIdentityId, bridgeInstanceId, codexSourceId)`. Wire, manifests, Mobile foreign keys, product caches/checkpoints and exports carry the complete tuple; Bridge-local tables may treat installation metadata as an implicit constant only where the frozen schema permits. Route and filesystem path are transport/locator data, never identity. Before signed identity/source proof, discovery and legacy routes remain quarantined route candidates and must not read or merge an existing partition.

### 2.2 Four file-related surfaces that must stay distinct

| Surface | User intent | Object/result | Session effect |
|---|---|---|---|
| Agent artifact reference | Open/share/download a provider-produced result | Durable opaque `artifactId` plus short-lived resource ticket | Read-only projection; never a manual file mutation |
| Manual file management | Browse/search/read/download or explicitly mutate Mac files | `rootId + relativePath + fileIdentity/nodeRevision`; mutation proof for exact action | No timeline write |
| Home drop | Move a phone file to the Mac | Transfer ledger result and Mac landing receipt | Pure transport; does not create a draft, mention or session message |
| Composer attachment | Stage local file, then attach it to an explicit prompt | Attachment ref backed by successful Mac landing or accepted inline image | Only explicit Send creates a Session Kernel operation |

The same bytes may pass through the transfer content plane, but the UI entry, authority, lifecycle and result type remain different. A successful Home drop cannot silently appear in a composer; an artifact ref cannot grant arbitrary neighboring-file access; a manually downloaded file cannot be treated as provider lineage.

### 2.3 Control plane and content plane

Control-plane WebSocket messages carry typed descriptors, state changes, request correlation, the frozen execution context fences, transfer offsets and opaque references. Every product control envelope is at most 64 KiB; oversize fails before OperationKernel admission and cannot create partial operation state. It does not carry file/image/video bytes or expose canonical Mac paths to general UI.

Every typed mutation uses a schema-generated RFC 8785 canonical fingerprint over semantic payload and preconditions. Route, connection epoch, UI label and retry counter are excluded as frozen by OperationKernel. String code points are preserved exactly: no NFC/NFD or other Unicode rewrite occurs during fingerprinting. Basename/path validation may reject unsafe separators or lengths, but cannot silently normalize the user's semantic input. Content SHA-256/ETag and Git hunk hashes are domain evidence, not substitutes for the OperationKernel fingerprint.

The HTTP content plane carries byte ranges and upload chunks. Its bearer/ticket is short-lived, method-scoped, object-scoped, size/range-scoped and bound to the authenticated connection/actor policy. `HEAD` discovers current offset/metadata; `GET` uses a single `Range` and exact `If-Range: ETag`; `PATCH` requires `Upload-Offset` and `application/offset+octet-stream`. Reconnect renews a content ticket through the authenticated control plane; it does not turn a stale route token into durable authority.

### 2.4 Capacity and atomicity invariants

| Invariant | Value / rule |
|---|---|
| Maximum ordinary transfer | 15 GiB per file, both directions |
| Maximum preview resource | 2 GiB; renderer-specific auto-preview limits may be lower |
| Inline composer image | PNG/JPEG only, at most 20 MiB; everything else uses transfer staging |
| Transfer HTTP chunk | At most 16 MiB; Mobile adapts between 1 and 16 MiB |
| Mobile receive reserve | At least 512 MiB free after the planned landing |
| Upload concurrency | Existing serialized ingress per drop batch; preserve Bridge/Mobile bounded global queues |
| Landing | Private same-volume partial, fsync/close as platform permits, digest verification, atomic no-clobber commit |
| Name collision | Deterministic suffix; never overwrite an existing destination |
| Resume | Stable transfer ID/checkpoint within retention; source identity + ETag + size must match |
| Digest | Whole-file SHA-256 for ordinary transfer is a required addition; ETag remains the version/resume validator, not the digest |

Current source has ordinary-transfer ETag and stat identity, while SHA-256 is implemented for the diagnostic-report path. The v4 target therefore adds a streaming whole-file SHA-256 manifest/result for normal upload and download. The producer computes it without full buffering; the receiver verifies it before atomic landing. The independent file-transfer `FT/2` may remain a compatibility path, but its UI must say “completed” rather than “digest verified”; it is not Conversation Sync V2.

### 2.5 Shared lifecycle grammar

Feature stores use explicit states and feature-owned progress/read ledgers:

`idle → preparing → authorized → active → paused/retrying → verifying → committing → succeeded | failed | cancelled | expired`

Not every capability uses every state. For mutations, feature state is a projection of the unique OperationKernel record plus domain evidence, never a competing authority. A generation or identity mismatch fails stale work rather than applying it to the new route/source. Recoverable transfer progress preserves bounded checkpoints; cancellation removes leases and private partials when no resume is requested; retention cleanup is safe, idempotent and never deletes a user-visible committed file.

## 3. P-001 — Computer and route management

### User entry and product behavior

Entry points remain Home machine cards, connection/settings management, setup QR and edit sheets. A computer card expands into routes. The user can connect via preferred route, add/edit a LAN/Tailscale/DNS/manual/SSH/jump route, favorite, explicitly reorder computers and routes, test one route, stop a remote Bridge where supported, or delete one route/computer after impact confirmation.

The current source already models signed Bridge identity, `bridgeInstanceId`, `codexSourceId`, route health and route grouping. `MachineManagerService` persists route records in `machines_v2` and secrets in secure storage. `BridgeMachineGroup` prefers signed identity, then legacy instance identity, and isolates unproven routes. `MachineGroupCard` already exposes route-specific actions. Preserve these effects.

### Identity, state, storage and lifecycle

- Computer grouping key: frozen `bridgeIdentityId` after proof; legacy `bridgeInstanceId` may form a quarantined compatibility group but cannot silently rebind a signed computer or become the canonical grouping key.
- `RouteId`: current `Machine.id`, stable across label/host edits; never a data namespace.
- Route state: `unknown`, `checking`, `online`, `offline`, `unreachable`, `identityChanged`, plus latency/version/last checked.
- Persist route configuration and explicit `computerDisplayOrder`/`routeDisplayOrder`; keep health observations memory-only and refresh them.
- Keep API keys/SSH credentials in secure storage. Never duplicate them in SharedPreferences, QR logs or diagnostics.
- Deleting the last route removes only the saved access object and asks separately whether bounded local caches should be forgotten. It cannot delete Bridge data or sessions.

### Execution and errors

Mobile owns editing, sorting, credential references, health presentation and route choice. These local preferences do not enter OperationKernel. Bridge supplies signed identity/readiness after connection. An authenticated Bridge-side control such as remote stop is a typed OperationKernel mutation; it cannot be a raw transport command. SSH startup/tunnel stays Mobile-route infrastructure. Errors distinguish invalid address, DNS/Tailscale unreachable, SSH auth/tunnel failure, transport timeout, auth failure, signed identity mismatch, source mismatch and application not ready.

`BridgeInstallationStore` alone owns `bridgeInstanceId`; `SourceRegistry` alone persists `codexSourceId`. Machine preferences only retain previously verified hints and must never mint or repair either value. Cold start shows saved computers but performs no automatic authenticated WS connection. A user tap initiates a route attempt; automatic reconnect is allowed only for that user-selected route intent and is stopped by identity/auth mismatch.

### Source disposition

| Source | Disposition |
|---|---|
| `apps/mobile/lib/models/machine.dart`, `machine_route_grouping.dart` | `KEEP + ADAPT`: preserve route/group facts; bind IDs to frozen identity types. |
| `machine_manager_service.dart`, manager Cubit/cards/edit sheets | `KEEP + ADAPT`: add explicit stable ordering; keep route preference independent from data caches. |
| SSH startup/tunnel services, connection URL parser | `KEEP`: route mechanisms only. |
| Route-keyed data/cache ownership or silent signed-ID rebind | `DELETE`; no runtime migration or fallback authority. |

### Acceptance and rollback

Source tests must prove add/edit/reorder/favorite/delete, signed mismatch isolation, legacy quarantine, IPv4/IPv6 and independent route health. Runtime acceptance needs two routes to one Bridge, route switch with the same source partition, and a deliberate identity mismatch. Device acceptance repeats via LAN/Tailscale and SSH where configured. Rollback disables explicit reorder and new identity adapter while preserving saved route JSON and secure credentials; it must not rewrite them to a route-as-computer schema.

## 4. P-002 — Signed identity, pairing and authenticated actor

### Existing seam and target behavior

Reuse Bridge Ed25519 identity at `~/.ccpocket/bridge-identity-v1.json`, the pairing/trusted-device stores, auth modes `key`, `paired_or_key`, `open`, the Mobile device Ed25519 identity, and the WebSocket-lifetime HTTP bearer. Files remain owner-only (`0700` directory, `0600` state), corrupt/key-mismatched identity fails closed, and pairing never aliases the Secure Enclave key used for file mutation proof.

Pairing entry is connection setup: scan a QR with a 256-bit token, complete challenge/signature, show the short local approval code, and require explicit local approval. Initial pairing is the necessary pre-auth bootstrap and does not pretend to have an execution context. Pairing tokens expire after five minutes; the current bounded token/trusted/pending stores and ten-second handshake timeout are retained. An already authenticated owner can see and revoke trusted phones through a typed OperationKernel mutation; revocation terminates/invalidates their active content leases.

### Frozen execution context

The current connection-auth map exposes an optional `deviceId`, but target product operations consume the frozen `AuthenticatedExecutionContext` injected by transport. It includes the complete `SourcePartition`, `sourceEpoch`, `connectionEpoch` and server-derived actor principal/key/assurance. Request bodies do not carry authoritative `actor`, `claimantId`, `deviceId` or `authenticated=true`; a legacy echoed value can only be checked for equality and never adds authority. Owner capability and step-up requirements are derived on Bridge from that context and current policy. Mobile-provided booleans never establish actor or biometric success.

### Mode matrix

| Mode | WS/product read | HTTP content | Full-disk owner read | File/Git destructive mutation |
|---|---|---|---|---|
| Paired device | authenticated | socket-lifetime bearer/ticket | only when server owner policy also permits | exact step-up/explicit product authorization |
| API key | authenticated | socket-lifetime bearer/ticket | only with exact owner policy | exact password proof or separately authorized Git action |
| Loopback CLI | local typed command | local only | command-specific allowlist | command-specific explicit input |
| Open | readiness GET and deliberately narrow diagnostics only | none by default | never | never |

### Source disposition, acceptance and rollback

`bridge-identity.ts`, `bridge-device-pairing.ts`, `bridge-connection-auth.ts`, `bridge-http-auth.ts`, Mobile identity/pairing services and pairing UI are `KEEP + ADAPT`. The adapter constructs the frozen execution context; there is no core amendment. Delete no signed state format. Tests cover corrupt stores, expiry, replay, duplicate approval, revoked device, remote-address bearer misuse and open-mode denial. Physical-device acceptance pairs, reconnects, revokes, and proves all content endpoints fail afterward. Rollback disables new context-required product mutations, leaving pairing/read-only connection functional; it never falls back to trusting a client flag.

## 5. P-003 — Discovery and route promotion

### Product flow

Setup offers manual LAN/Tailscale/DNS, QR, SSH and discovered candidates. Discovery results are suggestions, not computers. A row shows source, address, expiry/last seen and verification state. The user selects a candidate; Mobile connects, authenticates, verifies signed Bridge identity and source, then explicitly saves or attaches the route to an existing computer.

Current Bonsoir discovery collapses results to `host:port` and carries only name/host/port/auth-required. Bridge mDNS advertises version/auth and is intentionally disabled on macOS. Therefore the target is a `NEW_MINIMAL` feature DTO such as `DiscoveryCandidate(routeCandidateId, source, host, port, observedAt, expiresAt, advertisedAuth, advertisedIdentityHint?, status)`. Advertised identity is only a hint; the authenticated handshake is authoritative.

### Route sources and lifecycle

| Source | Behavior |
|---|---|
| LAN/mDNS | Expiring volatile candidate; do not re-enable macOS advertisement without a separately verified product decision. |
| Tailscale/DNS | User-entered/saved ordinary route; Tailscale Serve may terminate TCP to loopback but is not identity. |
| QR | Carries address/bootstrap/pairing data with bounded expiry; secrets never persist in logs. |
| SSH/jump | Saved route with secure credentials; start/test/tunnel errors are route errors. SSL jump tunnel remains explicitly unsupported until implemented. |

Candidate states are `seen`, `expired`, `connecting`, `identityVerified`, `authRequired`, `identityMismatch`, `unreachable`, `saved`. Promotion succeeds only after the connection yields an `AuthenticatedExecutionContext` whose complete SourcePartition matches the verified result. Discovery stops with the screen/background lifecycle and removes expired unsaved rows. It never opens a session or writes timeline.

### Source disposition, acceptance and rollback

`server_discovery_service.dart`, setup guide, QR parser, SSH services and route editor are `KEEP + ADAPT`. Add source/TTL/status and promotion UI; do not replace route storage. `mdns.ts` is `KEEP` with the current macOS-disable policy. Acceptance injects duplicate host addresses, reused IP with a different signing key, expired QR, two discovery sources for one Bridge and cold-start no-autoconnect. Rollback hides live discovery while preserving manual/QR/SSH route entry.

## 6. P-004 — Application readiness and entry progress

### Definition of ready

TCP/WS open is not ready. Authentication alone is not ready. Home becomes usable only when the same connection generation has completed transport, signed identity/auth, source proof, capability negotiation, required Bridge managers, catalog/session-list decode, canonical cache commit and required runtime/projection initialization.

Reuse Bridge `bridge-readiness.ts`, `/health`, authenticated readiness, and the deliberately narrow unauthenticated `GET /readyz`. `/health` is liveness plus readiness detail; `/readyz` returns 200/503 and permits only GET in open readiness mode. Degraded optional features do not falsely fail the whole Bridge, but each capability advertises its own availability/error.

Mobile preserves the current staged progress model and generation fences: connection milestones reach 78, canonical sync commits drive 98, runtime/projection readiness drives 99/100. The existing ten-second authority watchdog and stall recovery stay. Duplicated readiness decisions in screens and `BridgeService` should be adapted behind one Mobile orchestrator, not moved into Session Kernel.

### State and recovery

`routeSelected → transport → authenticated → identityVerified → capabilities → bridgeReady → catalogLoading → catalogCommitted → runtimeReady → ready`

Errors identify the failed stage and generation. Recovery offers retry same route, choose another route, repair auth/pairing, update Bridge for unsupported required capability, or open bounded diagnostics. Background `notifications_only` mode does not make the foreground shell ready and cannot mutate foreground projections.

### Binding, source disposition and acceptance

This is `FROZEN_BINDING / USE_EXISTING`: readiness consumes `AuthenticatedExecutionContext.sourceEpoch` and the complete SourcePartition; the detailed readiness snapshot remains product-local and cannot redefine source authority. Bridge readiness implementation and tests are `KEEP`; Mobile readiness tests, progress UI and watchdog are `KEEP + ADAPT`. Delete screen-local “socket means ready” shortcuts. Acceptance forces stale late frames, manager-not-ready, catalog decode failure, authority timeout, reconnect during 98% and optional feature degradation. Rollback shows the current staged screen but still fails closed before catalog commit; never revert to WS-open entry.

## 7. P-005 — Manual file browser and search

### Entry and read surface

The file browser remains a Home/product-shell entry, independent of any session. It lists roots, folders and files; seeds Desktop, Downloads and Documents pins once; supports pin/unpin, paging, bounded search, stat, metadata, preview and download. Owner mode may expose `/` plus allowed roots for read; non-owner users remain within configured allowed directories/Home.

File identity is not an absolute path on Mobile. It is `(SourcePartition, rootId, relativePath, fileIdentity, nodeRevision)` with directory revision for list/search snapshots. A result can carry safe display name, type, size, timestamps and preview/download actions. Canonical absolute paths remain Bridge-private except the separately bounded composer landing receipt needed by provider mention adaptation.

### Authority and traversal safety

- Owner full-disk read requires exact `BRIDGE_ALLOWED_DIRS=*` and an authenticated key/paired policy. Open mode fails closed to Home/allowed roots.
- Every access re-resolves the opaque root and relative path using no-follow/canonical checks; symlink traversal, device/special files and identity changes fail.
- Search inherits the selected root and hidden-file policy. It cannot use arbitrary shell commands or accept an absolute cwd.
- Read authority never implies create/write/move/trash/delete. P-008 governs those actions.

### Bounds and lifecycle

Reuse current list default/max 100/200, stat/roots limits, 4096-byte relative paths, per-client/global concurrency 2/4, two-minute cursor TTL, eight cursors per client, 100,000 native directory entries, 16 MiB name budget and 2 MiB helper output. Preview rejects resources above 2 GiB; download delegates to the 15 GiB transfer service.

Actual source has no usable search request or search UI despite the package map claiming it. Add `NEW_MINIMAL` `file_browser_search_v1` behind the existing local-feature slot: root-scoped query, cursor, max 200 results/page, serialized control page at most 64 KiB, server total/deadline/byte budget, cancellation, hidden-file flag, directory revision and `truncated` reason. Search results expire with their cursor and must be re-statted before open/download/mutation.

Pins currently include logical route identity. New pins use the complete frozen SourcePartition. Legacy route-keyed/two-component pin caches remain unopened and are not rewritten; users may repin after the complete partition is proven. Route change must not hide new pins for the same partition.

### Source disposition, acceptance and rollback

`file-browser-manager.ts`, POSIX backend/helper, slot protocol, Mobile service/screen and tests are `KEEP + ADAPT`; add search in those modules rather than a new file core. `file_peek` remains a small-file convenience client of the same safe read/preview path. Route-keyed/two-component pins stay unopened. Acceptance covers 100k-entry folders, Unicode/hidden names, cursor expiry, symlink swaps, file replacement after list, owner `/` read, open-mode denial, source switch and 2 GiB boundary. Rollback hides search and continues existing paged list/stat/preview/download; it does not loosen roots.

## 8. P-006 — Resumable file transfer

### User flows

Mac-to-phone begins from file browser download, artifact download, Gallery/capture share-download, or the authorized loopback send command. Phone-to-Mac begins from Home drop/transfer sheet or composer staging. The transfer sheet/recent inbox owns progress, pause/resume/cancel/retry, destination and share/open-after-receive. No transfer progress becomes a Session timeline row.

### Object identity and state

The transfer ledger key is SourcePartition-scoped `transferId`, direction and object generation; resume secret/ticket is stored only in secure storage. Download identity includes canonical Bridge-side source identity, size and ETag. Upload identity includes stable resume token, declared size/name/purpose and partial identity. Checkpoints and recent results partition by the complete SourcePartition, while the active route supplies only the current HTTP origin.

Current states (`queued`, `preparing`, `transferring`, `paused`, `succeeded`, `failed`, `cancelled`) become the shared lifecycle grammar with explicit `verifying` and `committing`. A reconnect obtains a fresh ticket and resumes from the verified offset; a source/ETag/size/digest mismatch creates a new transfer or fails, never appends to the old partial.

### Byte protocol and integrity

Keep independent file-transfer `FT/2` control and HTTP bytes, HEAD/PATCH offsets, single-range GET, exact If-Range ETag, 16 MiB max chunk, adaptive 1–16 MiB Mobile chunks, 15 GiB max, 24-hour default leases and seven-day state retention. Preserve Bridge active-download bound 4, 60-second idle and 15-minute request total, Mobile receive queue 8/30 GiB, 512 MiB reserve and native iOS 15/API FT/2 fail-closed gate.

Add an ordinary-transfer digest extension (`NEW_MINIMAL`, additive `FT/3`). A Mac-to-phone offer carries the Bridge-computed `digestAlgorithm=sha256`, 64-hex digest, size and immutable source generation. For phone-to-Mac, Mobile hashes while streaming and sends an explicit `upload_finalize_ft3(expectedOffset, sha256)` after the last PATCH; Bridge independently hashes the private partial and stays in `verifying` until they match. Completion receipts return the verified digest. The receiver cannot expose or atomically land the final file before digest success. ETag remains required for range resume. Diagnostic-report SHA-256 cannot be reused as proof that ordinary transfer already implements this.

Landing uses a private same-volume partial and atomic hard-link/rename-style no-clobber commit with deterministic collision suffix. A crash during commit is reconciled using the persisted identity/receipt. Never overwrite a destination chosen earlier, even if it appears between prepare and commit.

### Execution placement and compatibility

Bridge owns source stat/canonicalization, download leases, upload partials/reservations, HTTP enforcement, digest/landing and crash recovery. The Mac landing is a typed OperationKernel mutation: admission binds the frozen execution context and RFC 8785 semantic fingerprint before the transfer executor may commit; progress offsets and content SHA-256 remain transfer evidence, not operation identity. Mobile owns pick/drop, security-scoped input staging, checkpoints, destination capacity, adaptive chunks, inbox/unread and native Files export. iOS `FileTransferPlugin.swift` owns native file coordination and no-clobber export; Flutter fails closed on iOS <15 or native API mismatch.

`FT/2` remains resumable and safe by ETag/identity but is labeled not digest-verified. `FT/3` composer path requires a finalized ContentRef; if only FT/2 is available, ordinary transfer may complete but the composer attachment remains unsupported rather than guessing a path.

### Source disposition, acceptance and rollback

All `file-transfer-*` Bridge modules, Mobile transfer services/storage/HTTP/UI, native plugin and focused tests are `KEEP + ADAPT`. Add digest fields/calculation and complete SourcePartition scope; do not rewrite the transfer engine. Acceptance covers 0/1 byte, 15 GiB exact and +1 rejection, network loss at every chunk boundary, Bridge/app restart, ETag/digest mismatch, disk exhaustion, name collision, symlink/source replacement, cancel/expiry and native export. Physical-device tests must cover background/foreground, Files picker, low disk and share. Rollback negotiates FT/2 with truthful integrity labeling and disables digest-required consumers; it never disables no-overwrite/atomic landing.

## 9. P-007 — iOS ingress, Home drop and composer attachment

### Ingress classification

One serial ingress classifier receives picker, paste or drag/drop items. PNG/JPEG at most 20 MiB may become inline composer image bytes. Every other item, any oversized image, unknown-size provider or Home drop uses P-006 streaming up to 15 GiB with periodic capacity checks. A batch is at most 64 items; filenames are validated as safe UTF-8 basenames and capped at 255 bytes. Unsafe separators/control characters are rejected or mapped only by an explicitly displayed landing-name policy; Unicode normalization is never performed for mutation fingerprinting.

Home drop immediately asks for a Mac destination/authorization as required, enqueues transfer, and reports a transfer receipt. It never selects a session, changes composer draft or synthesizes chat.

Composer ingress creates feature-local attachments in `uploading`, `ready`, `failed`, `cancelled`. A ready large attachment contains a finalized `ContentRef` and immutable `ComposerAttachmentRef`; the Codex adapter resolves only the registered structured attachment form at send time. Claude remains an unreachable `NOT_IMPLEMENTED` seam and has no attachment path. Send is disabled while any required item is uploading. Only the user's explicit Send submits current text plus immutable attachment/content refs through OperationKernel; feature-local staging cannot write operation or timeline state.

### Privacy, lifecycle and failures

Security-scoped picker access is released after staging. Partial phone/Mac files follow transfer retention. Removing a composer chip cancels its transfer when safe and removes only feature-local draft state. Draft persistence stores attachment IDs/status, never tokens or raw bytes beyond the bounded inline image case.

Errors distinguish unsupported Codex attachment capability, picker permission, item-provider read failure, unknown/too-large size, capacity, transfer paused/expired, digest failure, mutation step-up failure, missing FT/3 landing receipt, connection/source change and explicit send failure. A ready attachment survives route switch only after the same Bridge/source is proved.

### Source disposition, acceptance and rollback

`file_drop_ingress.dart`, chat input/drop zones, transfer staging and Codex mention adapters are `KEEP + ADAPT`. Operation ownership and ContentRef/ComposerAttachmentRef naming are `FROZEN_BINDING / USE_EXISTING`. Delete any compatibility path that sends a message before landing or treats Home drop as attachment. Acceptance covers multi-item ordering, inline boundary, unknown size, drop cancellation, reconnect, route/source mismatch, explicit send once, no-send removal and FT/2-only unsupported composer behavior. Physical-device validation must use Files/iCloud security-scoped URLs and real drag/drop/paste. Rollback keeps Home transfer and inline images when they meet the frozen source/actor contract, while disabling large composer attachments on an incompatible file-transfer host.

## 10. P-008 — Full-disk read and exact file mutation proof

### Policy split

Owner full-disk **read** is a server policy and authenticated actor capability. It does not authorize mutation. Every manual filesystem mutation requires a fresh proof for one exact operation. Pairing/API-key/connection bearer does not replace step-up. Agent/provider file tools retain their provider permission system and are not routed through manual file-manager proof.

The current `file-mutation-auth.ts` securely stores password/device enrollment, uses Argon2id (legacy scrypt read), rate limits password failure, and verifies a Secure Enclave P-256 signature over a bounded challenge. But its operation is upload-only and omits the frozen execution context, canonical target and file identity. Extend it as an OperationKernel step-up verifier; it does not admit mutations, own operation identity/state or create an authorization core.

### Operation inventory

| Kind | Required exact fields | Default UX |
|---|---|---|
| `createFile`, `mkdir`, `upload` | canonical parent identity, validated basename preserving Unicode code points, expected absence, size/digest where applicable | confirm target; no overwrite |
| `write`, `append`, `overwrite`, `replace` | canonical target, expected file identity/revision, byte range or replacement digest/size | explicit destructive label; temp + atomic replace |
| `rename`, `move` | canonical source identity, canonical target parent/name, target expected absence | show old/new paths |
| `trash` | canonical target and identity | default delete action; reversible where platform supports |
| `deletePermanent` | canonical target and identity | separate red destructive proof; never implied by trash proof |

### Proof descriptor and verifier

OperationKernel preflight validates the typed mutation and computes its versioned RFC 8785 fingerprint from kind, schema, exact SourcePartition-scoped target, semantic payload and preconditions. It preserves Unicode code points without NFC/NFD rewriting. The step-up challenge binds `operationId`, `fingerprintVersion`, `operationFingerprint`, actor principal/key, complete SourcePartition, source epoch, canonical root-relative source/target, expected source/target identities/revisions/absence, nonce, issued/expiry and display summary. Password or biometric authorizes that exact descriptor. Proof is single-use, expires in at most 60 seconds, is consumed on any verification attempt, and is invalid after actor revocation, source epoch change or filesystem re-stat mismatch. Connection epoch may fence delivery but is excluded from the frozen semantic fingerprint.

After OperationKernel admission and successful step-up, the file executor reopens parents/targets without following symlinks, compares identity, checks capacity and executes the typed operation; executor evidence drives OperationKernel reconciliation. Client-reported Face ID success, filename-only approval or a proof for a neighboring target is rejected. Password and biometric use the same operation fingerprint; biometrics bind `biometryCurrentSet`. Device enrollment/revoke/reset remain explicit local-owner actions.

### Storage, execution, acceptance and rollback

Keep the owner-only mutation store at `~/.ccpocket/file-mutation-auth-v1.json`, password length 8–256, eight enrolled devices, 64 active challenges, five-failure/30-second password block and 0600 permissions. Migrate schema additively with versioned descriptors. Bridge owns all path and operation execution; Mobile Secure Enclave owns only local-key use/UI authentication.

`file-mutation-auth.ts`, file-browser mutation host/native code and tests are `KEEP + ADAPT`; upload-only descriptor validation is `REWRITE` within the same module. This is `FROZEN_BINDING / USE_EXISTING`, not a core amendment. Acceptance attacks replay, expiry, cross-client proof, path swap, symlink race, target-created race, wrong SourcePartition/source epoch, Unicode normalization collision, biometric-set change, password throttling and crash before/after atomic commit. Rollback exposes read-only browser and existing safe upload transfer only when its exact legacy proof is supported; all other mutations fail closed.

## 11. P-009 — Quick Look-first preview

### Renderer policy

Preview is a product service over an opaque ref/ticket. It does not read arbitrary Mobile-provided paths. The state flow is `resolving → preparing → nativeQuickLook | boundedFallback → ready | metadataOnly | failed`, with cancel/expiry and explicit retry/renew.

On iOS, ask the native Quick Look plugin whether it can preview the staged app-sandbox file. Current policy automatically stages non-HTML resources up to 64 MiB for Quick Look; the native answer is authoritative. HTML deliberately uses the bounded local WebView path. Quick Look failure automatically falls back to bounded renderer/metadata rather than presenting a false hard failure. JSON/text/image/PDF and supported office types use the same policy; unknown binary shows metadata plus download/share.

The resource limit is 2 GiB. Renderer memory and automatic staging limits may be smaller and must be visible as `tooLargeForAutoPreview`, not silently read in full. HTML/DOCX fallback JS is restricted, navigation stays same-origin within bounded artifact routes, and external navigation requires explicit user action. Temp preview files are named safely and removed at screen/service lifecycle end.

### Source disposition, acceptance and rollback

This uses `FROZEN_BINDING: AuthenticatedExecutionContext / ContentRef / ContentAccessTicket` with `NO_CORE_CHANGE / USE_EXISTING`. `ArtifactQuickLookPlugin.swift`, preview screen/service, HTML document builder, line preview and tests are `KEEP`. Adapt only the ref/ticket adapter and error taxonomy. Acceptance covers native can/cannot preview, QL exception fallback, HTML script/navigation sandbox, 64 MiB auto boundary, 2 GiB hard boundary, expired ticket renewal, offline metadata and temp cleanup. Physical-device Quick Look and share sheet are separate gates. Rollback disables a failing renderer and leaves download/share/metadata; it never broadens file access.

## 12. P-010 — Agent artifacts and resource tickets

### Durable ref versus short lease

An agent artifact is durable lineage metadata, not a permanent URL. Reuse `ArtifactRegistry` with `artifactId`, candidate key, owner durable session ID, message/provider item identity, canonical source identity, kind, created/access/expiry and file identity. Mobile receives a safe `ArtifactRef` with no absolute path or bearer.

Opening resolves the ref through the authenticated control plane. Bridge validates artifact owner/message/candidate root/source and current file identity, then issues a short resource ticket. The current store already uses a 43-character token, one-hour default lease (60 seconds–24 hours), maximum 100 active tokens, 2 GiB max and regular-file/allowed-root checks. Preserve those bounds.

### Ticket amendment

The root contract freezes `ContentOffer` for unfinished work, finalized durable `ContentRef`, and short-lived `ContentAccessTicket`; `ComposerAttachmentRef` is the immutable composer input. The machine registry/schema must preserve these semantics without creating a Phase 2 authority:

- actor, complete SourcePartition, source epoch and connection/lease generation;
- content/object generation and current file identity;
- allowed methods (`HEAD`, `GET`) and range/size ceiling;
- MIME/type and object generation; required SHA-256 belongs to finalized `ContentRef`, while HTTP ETag/Digest proves the served generation;
- issued/expiry/revocation and single-origin audience.

Artifact durable registry retention remains feature-owned (currently up to 5000 entries and 180 days). Short tickets stay in memory and are renewable; revocation, file replacement or owner mismatch invalidates them. Artifact share/download delegates to preview/transfer and does not grant directory browsing. Tickets do not duplicate the content digest and never become durable timeline data.

### Execution, source disposition and acceptance

Bridge owns candidate extraction, registry, source/root/identity checks and HTTP byte serving. Mobile owns link detection, open/refresh/share/download presentation. All `artifact-*`, `generated-artifact-store.ts`, Mobile artifact widgets/services and tests are `KEEP + ADAPT`; replace raw durable URL assumptions with ref resolution but do not delete existing opaque IDs. Acceptance covers cross-session ref theft, replaced file, expired/renewed ticket, range/HEAD, route switch same source, source mismatch, 100-token eviction and 2 GiB boundary. Rollback retains current short URLs behind the same authenticated resolver and disables cross-route renewal; never expose absolute path.

## 13. P-011 — Gallery, message images and generated media

### Three lineages, one media shell

Keep the existing user-visible gallery and image viewers, but preserve lineage:

1. Screenshot/gallery item: persistent Bridge gallery ID, capture/project/source metadata.
2. Provider message image: provider/session/message item identity plus process-memory or provider-backed content ref.
3. Generated artifact image: artifact/content ref and provider lineage.

These may share grid/viewer/share components, but must not share an ID namespace or infer project ownership from display `projectName`.

### Current gaps and target contract

`GalleryStore` currently persists supported PNG/JPEG/GIF/WebP up to 10 MiB with 0600 files, but lists all rows without pagination/retention/count budget. `ImageStore` keeps at most 100 images in process memory, supports WebP thumbnails and 10 MiB full images. HTTP list/upload/delete is authenticated, while individual gallery/image GET routes are not uniformly authenticated. Mobile requests and renders the full list. These are `ADAPT/REWRITE` points, not reasons to replace the stores.

Every thumbnail/full/download route requires actor/ticket authorization. Add cursor paging, thumbnail descriptors, canonical SourcePartition/project/session lineage, content generation/ETag, missing/expired states and bounded retention/storage. Default proposal: at most 100 items and 64 KiB serialized descriptors per page, server-configurable count/byte/age budget, newest-first stable cursor and cleanup that never deletes an external source file. Base64 upload remains only for small bounded compatibility input; normal media bytes use the content plane/transfer.

Viewer states are `thumbnail`, `loadingFull`, `ready`, `expiredRenewable`, `sourceMissing`, `unsupported`, `failed`; actions are open, zoom, metadata, download/share, and delete only for gallery-owned copies. Deleting an index entry never deletes an agent artifact or source project file.

### Binding, source disposition and acceptance

ContentOffer/ContentRef lineage is `FROZEN_BINDING`; actor/source and mutation ownership are frozen through `AuthenticatedExecutionContext` and `OperationKernel`. Gallery upload/delete are typed OperationKernel mutations, while list/read/zoom stay product reads. `gallery-store.ts`, `image-store.ts`, Gallery screen/widgets, message/generated image viewers and tests are `KEEP + ADAPT`; unauthenticated individual GET, full-list reads and project-name ownership are `REWRITE`. Acceptance probes unauthenticated URLs, cross-actor/SourcePartition refs, >100 items paging, retention, expired in-memory image, malformed formats, 10 MiB boundary, thumbnail/full generation and delete ownership. Physical-device validation covers zoom, memory pressure, download/share and offline thumbnails. Rollback disables uploads/delete and uses authenticated read-only paging; never restore open GET.

## 14. P-012 — Git and worktrees

### Product workspace and fact source

Git remains the sole fact source for status, staged/unstaged text diff, image diff, branches, commit identity, upstream/ahead/behind and worktrees. Session Kernel may reference a workspace projection but never stores Git rows as canonical history.

`GitWorkspace` is a product descriptor derived from an allowed canonical repo/worktree root, complete SourcePartition and current repository generation (`HEAD`, index/worktree observation). It never accepts an arbitrary cwd from a generic shell. Current path-allowed checks, typed `execFile` calls, image diff, hunk fingerprints, operation lane and project-path result correlation are retained.

### Action inventory and authorization

| Class | Actions | Product gate |
|---|---|---|
| Read | status, local diff, staged diff, image diff, branches, worktrees, remote status | authenticated allowed workspace; remote fetch is separately visible network activity |
| Reversible index | stage/unstage file or hunk | typed OperationKernel mutation; explicit tap; fresh diff/index generation |
| Durable local | create branch, checkout, commit | typed OperationKernel mutation; explicit sheet/confirmation; precondition on HEAD/index/worktree |
| Remote | fetch, pull, push | typed OperationKernel mutation with visible network intent/result; never background push/pull |
| Destructive | revert file/hunk/all, remove worktree | typed OperationKernel mutation; separate red confirmation plus exact target fingerprint; untracked clean/forced worktree removal disclosed |

Current hunk SHA-1 fingerprint protects displayed `+/-` content against stale stage/unstage/revert and remains domain evidence only. Operation identity is the frozen versioned RFC 8785 fingerprint computed by OperationKernel over the typed Git mutation, complete SourcePartition/workspace target, expected HEAD/index/worktree generation and exact file/hunk/confirmation preconditions. Filenames and branch names preserve Unicode code points without NFC/NFD rewrite. `AuthenticatedExecutionContext` supplies actor/source/source epoch; request payload cannot claim them. Bridge recomputes Git evidence before execution and returns `stale_conflict` with refresh instructions rather than guessing. OperationKernel is the sole mutation owner; GitService serializes/executes the admitted domain work and reports evidence for reconciliation. Read refresh can run separately with generation tagging.

Text/image diff is read data, not a control mutation payload. A diff response must not exceed the frozen 64 KiB control envelope: return bounded pages with stable repo/index generation or a pending ContentRef-family handle to the authenticated content plane. Existing unbounded `diff_result` frames are an `ADAPT` target. A page token is SourcePartition/workspace/generation scoped; stale paging fails rather than splicing two Git states.

Commit message assistance remains provider-specific and must use only staged diff, bounded to the existing 1 MiB local Bridge-to-assistant process buffer; that local buffer is not a WS control frame. Auto-generate requires the active session cwd match. The generated commit message still obeys the ordinary typed control text limit and is shown before commit. No automatic commit, push, pull, checkout or worktree delete.

Worktree creation/list/remove remains in `worktree.ts`/store. Only managed worktrees below the computed worktree root may be removed. Current `--force` removal and pre/post hooks are high impact: show dirty/untracked summary and hook disclosure; require exact confirmation. A failed hook is surfaced; it cannot be silently treated as successful lifecycle completion.

### Source disposition, acceptance and rollback

This consumes `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel` without changing either contract, so the decision is `NO_CORE_CHANGE / USE_EXISTING`. `git-operations.ts`, `git-assist.ts`, worktree modules, Git UI Cubits/widgets and tests are `KEEP + ADAPT`. Add typed OperationKernel mutation variants/preconditions and explicit confirmation for branch/remote/worktree actions. The direct typed operation switch may later move from giant `websocket.ts` into `ProductPlatform.GitService`, but do not rewrite commands as a generic shell. `revertFiles` untracked `git clean -fd` and forced worktree removal require `REWRITE` of authorization/preflight, not deletion of the user effect. Git assurance/confirmation is an OperationKernel precondition; it must not borrow the file biometric proof unless a future policy explicitly requires the same step-up.

Acceptance uses concurrent external Git edits to force stale HEAD/index/hunk, filenames beginning with dashes, binary/image changes, checked-out branch conflicts, detached HEAD, no upstream, merge conflict, network failure, dirty worktree removal and hook failure. Runtime validation uses a disposable repository only. Rollback disables mutation endpoints and leaves status/diff/branch/worktree read; it never retries a timed-out mutation against a new generation.

## 15. P-013 — Mac screenshot, screen recording and event replay

### Scope correction

Current `screenshot.ts` captures the full Mac display or one enumerated on-screen window using CoreGraphics and `screencapture`, then copies the PNG into Gallery. Current `recording-store.ts` records incoming/outgoing WebSocket events as JSONL for deterministic replay. It is **not** screen-video capture. The v4 wording “screen recording/event record” therefore represents two different CaptureService subtypes: an explicit Mac screen-video recording and a diagnostic event JSONL. They have separate consent, formats, retention and refs; neither is allowed to masquerade as the other.

### Screenshot flow

Entry remains the session toolbar screenshot sheet. It requests a fresh window list, shows owner/title, and lets the user explicitly select full screen or a window. Capture states are `requestingPermission`, `listingTargets`, `capturing`, `saving`, `ready`, `failed`, `cancelled`. Revalidate a selected window ID immediately; if stale, fail and ask the user to choose again—do not silently capture the full desktop, because that expands privacy scope.

Bridge/macOS owns Screen Recording permission, window enumeration and capture. Mobile owns target selection and result presentation. The selected screenshot request is a typed OperationKernel mutation; ScreenshotService performs capture/save after admission. A completed PNG becomes a Gallery/content ref only after the gallery copy succeeds; temp files are always removed. Capture timeout, permission denial, target disappearance, disk full and gallery failure are distinct errors.

### Screen-video recording flow

Screen video is a `NEW_MINIMAL` macOS product implementation behind CaptureService, not a Session Kernel feature and not an extension of JSONL. The user explicitly chooses a display or window, whether microphone/system audio is included, then taps Start. Start/stop/delete/export are typed OperationKernel mutations bound to `AuthenticatedExecutionContext`; CaptureService performs the admitted native effect. Mobile shows a persistent recording indicator, elapsed time, estimated bytes and Stop. Bridge revalidates the target and permission before starting and stops on user request, target loss, permission loss, capacity reserve or configured limit.

Use a native ScreenCaptureKit/AVFoundation helper with an explicit version handshake. Default format is an `.mp4` H.264 video without audio; optional audio tracks require separate consent and availability checks. The v4 safe default is the first of 30 minutes or 2 GiB so every successful recording remains within the in-app preview ceiling. A future product setting may permit a larger export-only file up to the 15 GiB transfer limit, but it must be labeled not previewable and is not the default.

Lifecycle is `permissionRequired → targetSelected → starting → recording → stopping → finalizing → ready | failed | cancelled`. Bytes land in an owner-only private partial with free-space reserve, then the helper finalizes the media container, computes SHA-256 and atomically publishes a capture-owned file plus ContentRef. An incomplete/crashed container is `recoveryAvailable` or deleted after retention; it never appears as a successful replayable item. List, playback, share/export and delete use authenticated paged descriptors. Playback uses a bounded native media player and never injects timeline rows.

### Event-recording flow

Event recording is off unless the server/user explicitly enables it. UI entry is a privacy/diagnostic screen, not the normal transcript. It exposes enable/start scope, stop, list, replay, export/share and delete. List is paged and source/actor-scoped. JSONL storage is append-only while active, owner-only on disk, size/count/age bounded, and finalized atomically with metadata/digest before it becomes replayable.

Redact or exclude bearer tokens, API keys, pairing secrets, file-transfer tickets, push tokens, mutation proofs and raw large content. The product must tell the user that prompts, responses, paths and approvals may be recorded. Body text, screen pixels and file bytes have independent privacy toggles; enabling event records never grants screenshot or file-content capture.

Recording states are `disabled`, `armed`, `recording`, `finalizing`, `ready`, `replaying`, `failed`, `deleting`. Enable/stop/export/delete are typed OperationKernel mutations; event append is the executor's bounded internal effect for an already admitted recording scope. A missing/truncated/corrupt JSONL row produces a bounded partial-replay warning; it does not crash or inject messages into a live Bridge. Replay uses `ReplayBridgeService` in an isolated read-only runtime and cannot send provider, Git, file or release mutations. JSONL/video bytes use the authenticated content plane through ContentOffer then finalized ContentRef; list/state control frames stay below 64 KiB. Sharing exports a redacted artifact through P-010/P-006. Delete removes JSONL/meta only after explicit confirmation and never deletes the source session.

### Current gaps, source disposition and acceptance

`screenshot.ts`, screenshot sheet, `recording-store.ts`, `recorded_event.dart`, loader, replay service and debug replay UI are `KEEP + ADAPT`. Silent stale-window fullscreen fallback is `REWRITE`. ScreenCaptureKit recording and event-record delete/share/paging/retention/redaction/finalization are `NEW_MINIMAL` additions inside CaptureService. The current whole-file `readFile`/unbounded list and recording metadata path exposure are `REWRITE`; no Session Kernel change is needed. Mutation ownership and completed content are `FROZEN_BINDING: AuthenticatedExecutionContext / OperationKernel / ContentOffer / ContentRef` with `NO_CORE_CHANGE / USE_EXISTING`.

Acceptance covers macOS permission denied/granted, stale window, full screen/window privacy, video target/audio consent, start/stop/target loss, 30-minute/2 GiB/capacity stop, playable container/digest, temp cleanup, Gallery failure, secrets in every message type, active-event-record crash, corrupt/truncated JSONL, bounded paging/retention, delete during playback/replay, isolated replay mutation attempts and share cancellation. Source tests do not satisfy macOS Screen Recording permission, ScreenCaptureKit runtime or physical-device playback/share acceptance. Rollback disables video first, then screenshot/event endpoints independently, and retains existing files for owner-local recovery; it must not expose unredacted recordings over the network.

## 16. Cross-capability source disposition

| Area | KEEP | ADAPT | REWRITE | DELETE/retire |
|---|---|---|---|---|
| Device/routes | Machine grouping/cards, secure credentials, connection mechanisms | Frozen SourcePartition, explicit ordering, full-partition caches | Any screen-local socket-ready decision | Route-as-data-identity and silent signed rebind |
| Pairing/readiness | Signed identity, pairing, connection bearer, readiness managers/watchdogs | Actor injection and source/generation snapshot | Client-asserted assurance | Open owner access, WS-open-as-ready |
| Browser/transfer | Root-scoped browser, POSIX safety, transfer engine, HTTP Range/offset, native plugin | Search, canonical checkpoint scope, whole-file digest | Upload-only mutation descriptor | Route-keyed cache authority or runtime migration |
| Preview/artifact | Opaque artifact IDs, registry, Quick Look/fallback, bounded short lease | ContentOffer/ContentRef/ContentAccessTicket adapter | Durable raw URL/path assumptions | Any absolute-path exposure |
| Gallery/media | Existing stores, thumbnails, viewers and Gallery UI | Auth, lineage, paging, retention | Open individual GET/full-list reads/name-based ownership | Base64 large-byte path |
| Git | Typed git/worktree commands, hunk fingerprints, UI/Cubits | OperationKernel variants, workspace generation, bounded diff reads | Destructive preflight and forced-remove disclosure | Generic shell fallback/automatic remote mutation |
| Capture | macOS screenshot, Gallery copy, event JSONL/replay | Privacy, state, ScreenCaptureKit video, bounded list/export/delete | Silent broader capture, whole-file/unredacted network read | Implicit recording or replay-to-live mutation |

No fallback may revive a deleted authority path. Compatibility is capability-negotiated, visible and fail-closed for mutation.

## 17. Acceptance gates

| Gate | Required evidence | Does not prove |
|---|---|---|
| Source | Focused Bridge/Flutter/native contract tests, type/analyze, fixture/fault tests | Running Bridge or delivered app |
| Bridge runtime | Candidate port, PID/build SHA, authenticated route, readiness, content HTTP, persisted-state restart | IPA or physical-device behavior |
| Mobile runtime | Candidate bundle identity, active route/source/generation, rendered states and errors | Native entitlement/OS picker/Quick Look |
| Native simulator | Plugin API version, capacity/atomic landing, Quick Look/capture failure mapping | Real Secure Enclave, Files/iCloud, background or Screen Recording permission |
| Physical device | Pair/revoke, route switch, Files ingress/export, 15 GiB fault/resume where feasible, biometric proof, Quick Look/share, memory/disk pressure | Release/stable deployment |
| Release | Signed artifact identity, install proof and rollback artifact | Stable promotion until separately authorized |

Minimum adversarial scenarios across the phase are stale route/source/generation, revoked actor, expired content ticket, symlink/file replacement, offset/ETag/digest mismatch, capacity loss, duplicate mutation result, old Bridge capability fallback, app/Bridge restart and concurrent external Git/file change.

## 18. Integration order and rollback points

1. Bind frozen SourcePartition, AuthenticatedExecutionContext and OperationKernel through adapters; keep all product services read-only initially.
2. Start Kernel/product data caches empty under the complete SourcePartition; preserve independently valid route preferences but do not import route-keyed/two-component data caches or checkpoints.
3. Enable browser search, authenticated media paging and preview/artifact ticket renewal.
4. Enable digest-capable file-transfer `FT/3` and `ComposerAttachmentRef`; if the independent existing file-transfer `FT/2` is retained, name and gate it explicitly and never confuse it with Conversation Sync V2.
5. Register exact manual file mutation variants in OperationKernel and add proof preconditions operation by operation, starting with no-overwrite upload/create and trash before permanent delete.
6. Register Git mutation variants in OperationKernel, then add repository generation and worktree destructive preflight.
7. Add capture privacy and event-record finalization/paging/export/delete; then gate ScreenCaptureKit video behind its own native/runtime/device acceptance.

Each step is an independent commit/feature flag and can fall back to the prior read-only surface. No rollback rewrites persistent signed identity, committed user files, Git history or canonical Session Kernel data.

## 19. Root adjudication closure

`05-CONTENT-AND-PRODUCT-OPERATIONS.md` closes the remaining cross-phase questions:

1. The names are `ContentOffer`, finalized durable `ContentRef`, short-lived `ContentAccessTicket` and immutable `ComposerAttachmentRef`.
2. Product mutations are namespaced sealed variants in the one central operation registry; `OperationKernel` owns their common lifecycle and product services execute admitted effects.
3. Legacy route-keyed/two-component data caches and checkpoints are `NO_IMPORT / NO_RUNTIME_MIGRATION`; independently valid route preferences may remain product-local.
4. Required SHA-256 belongs to finalized `ContentRef`; the ticket does not duplicate it.
5. Git uses the A0–A3 assurance/confirmation matrix and never implicitly borrows the file biometric proof.
6. Mutable Git/event indexes use generation-scoped bounded paging; stable reusable/export bytes materialize to `ContentRef` and use the common content plane.

All Phase 2 core-facing bindings are therefore frozen at the design level. Exact machine fields remain subject to registry/schema validation, but feature-local protocols cannot publish a second SourcePartition, execution context, mutation owner, operation fingerprint or operation-state authority.
