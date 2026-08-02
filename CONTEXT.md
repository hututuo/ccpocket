# CC Pocket Compatibility Fork Context

## 2026-08-02 shared durable-thread settings control

The source-verified correction is in:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/shared-thread-settings-control-20260802`
- Branch: `fix/shared-thread-settings-control-20260802`
- Bridge: `1dce49c7`
- Mobile: `08015a75`
- Audit: `notes/shared-thread-settings-control_v01_20260802-151806.md`

Shared Codex previously reused the transient runtime authority gate for every
setting write. An idle durable thread therefore showed settings but could not
change them without a runtime attachment, while a Desktop-active thread was
treated as settings-owned by Desktop. That rule confused exactly-once control
of the current turn with durable configuration for subsequent turns.

Bridge now capability-gates an exact source + durable thread settings target
and calls official `thread/settings/update` through the shared writer without
resuming, attaching or reading history. Current-turn stop, steer, approvals and
input remain protected by the existing runtime generation. Mobile makes idle
and Desktop-active durable settings editable only when this capability and an
authoritative source identity are present, and listens narrowly for the exact
thread's setting acknowledgements.

Bridge passed 114 files / 2,304 tests in a resource-isolated single-worker run;
Mobile passed 2,889 tests with four environment-only skips. Full analysis found
0 errors, 0 warnings and 52 existing infos. Source is verified but production
Bridge, OTA/IPA and physical-phone acceptance remain pending.

## Mandatory local Bridge production release SOP

Future `com.ccpocket.bridge` local production deployments are governed by
[`docs/bridge-local-production-release-sop.md`](docs/bridge-local-production-release-sop.md).
It is the single authoritative SOP for the release session: derive candidate and
probe environment from the live LaunchAgent plist, run real authenticated wire
smoke, change only `BRIDGE_CLI_ENTRY` after all gates pass, and retain an exact
rollback. It does not authorize a deployment by itself and keeps source,
runtime, Mobile/OTA/IPA, Cloud, physical-phone and `stable` gates separate.

## 2026-08-02 optional Bridge connection-key recovery

The active source lane is:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/optional-bridge-connection-auth-20260802`
- Branch: `feature/optional-bridge-connection-auth-20260802`
- Bridge commit: `e6e559d0`
- Mobile commit: `246dc703`

Bridge now separates the saved `BRIDGE_API_KEY` from the explicit
`BRIDGE_REQUIRE_API_KEY=1/0` switch. Unset keeps legacy key-presence behavior;
explicit `0` is the deliberate trusted-LAN opt-out. `/health` declares the
effective mode and bad credentials are rejected with HTTP 401 during the
WebSocket upgrade. The current production request remains auth-on.

Mobile now detects the additive health declaration, new 401 handshake, and
legacy 4001 close. Missing or rejected credentials stop the 5% bootstrap and
automatic reconnect loop, then offer secure local key replacement or QR
rescan. Generic network/WebSocket failures remain distinct. Bridge passed 114
files / 2,295 tests in single-worker mode; the focused Mobile connection,
dialog and home regression suite passed 89 tests, and targeted analyze was
clean. Runtime `1.69.6-compat.12-470900ee` is now production-deployed with
`BRIDGE_REQUIRE_API_KEY=1`; 401/valid-key protocol smoke, daemon readiness and
writer lease passed. The direct rollback is `df29b600`, and evidence is in
`runs/20260802-131342_bridge-1.69.6-compat.12-470900ee-deploy/DEPLOYMENT.md`.
Owner OTA remains blocked pending an exact build-212 cloud base and signing
material; physical-phone acceptance is separate and pending.

## 2026-08-02 focused Codex settings catalog correction and deployment

The current source-only correction is:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-dual-mode-compat-20260801`
- Branch: `fix/codex-dual-mode-compat-20260801`
- Product fix: `bb277214`
- Deterministic test-fixture follow-up: `30547f65`

The shared runtime authority was already correct, but the catalog still used a
bounded 128 KiB head plus 16 KiB tail parse for settings. In a roughly 341 MB
active rollout, the latest Codex model, effort, permission and collaboration
markers can sit outside both windows. The independent usage request still
returned quota, which explains the physical-phone combination of visible quota
with `未知 · 等待同步` controls. Later transcript activity could move a marker
into the tail and make the controls appear temporarily.

`conversation_sync_v2` now starts one non-blocking authoritative settings read
for the exact focused Codex thread. It does not delay the initial sync, does
not scan every catalog thread, deduplicates concurrent reads, retries bounded
failures and rejects a result if the catalog revision changed while it was in
flight. Sparse Bridge catalog refreshes retain an already complete settings
snapshot; an authoritative complete snapshot can still clear removed fields.
Mobile applies the same incomplete-versus-complete merge rule while committing
catalog pages to SQLite, so a later sparse page cannot erase known controls.

The exact 343,819,795-byte rollout returned nine authoritative setting fields
in a fresh-process measurement of 12.1 ms; this is a single observation, not a
p95 claim. Bridge passed 113 files / 2,275 tests. Mobile passed 2,879 tests with
four environment-only skips; full analysis reported 0 errors, 0 warnings and
52 existing infos, while the two changed Mobile files were clean. The full
Bridge run also exposed fixed-date Action Broker tests that expired after the
calendar crossed 2026-08-01; `30547f65` injects the fixture clock without
changing production behavior.

The inherited-parent metadata ownership correction in `df29b600` is now
production-deployed as runtime `1.69.6-compat.12-df29b600`; the exact focused
metadata and authenticated `conversation_sync_v2` complete-snapshot gate passed.
The direct rollback is `1.69.6-compat.12-652867a8`. The full production evidence
is in `runs/20260802-105110_bridge-1.69.6-compat.12-df29b600-deploy/DEPLOYMENT.md`.
Mobile OTA, IPA, Swift/native code, Cloud, VPN, Codex Desktop configuration and
user session data were not changed. Physical-phone acceptance remains pending.

## 2026-08-02 runtime authority lifecycle correction

The active source correction is in:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-dual-mode-compat-20260801`
- Branch: `fix/codex-dual-mode-compat-20260801`
- Code commit: `0848fd91`

Physical-phone evidence showed that a shared Codex attachment could become
ready while `conversation_sync_v2` still exposed the previous or empty
authority generation. A later Desktop transcript event accidentally refreshed
the projection, which made the conversation suddenly finish opening and made
model/effort controls reappear. Leaving and reopening reproduced the gap, and
settings then failed with `Shared Codex settings require an exact current
runtime target.`

`SessionManager` lifecycle updates now invalidate the content-free runtime
projection directly. The Bridge recomputes only the affected durable thread,
publishes the current execution host/control state/authority generation, and
does not reread catalog or history. The exact Mobile mutation fence remains
unchanged. Bridge passed 113 files / 2,271 tests in single-worker mode; Mobile
authority/preview regression files passed 201 tests. Source is committed and
the production Bridge now runs `1.69.6-compat.12` from source `652867a8` as PID
`64563`, with one `127.0.0.1:8765` listener and healthy `/health` and `/readyz`
signals. The existing LAN proxy remains unchanged. Physical-phone acceptance
of conversation reopen, model/effort controls, plan mode and stop remains a
separate gate; no Mobile, OTA, IPA, Cloud, VPN or Desktop configuration changed.

## Active shared Codex runtime implementation

On 2026-08-01 the user authorized a full-chain audit followed directly by
source remediation. The authoritative audit and remediation ledger is
`notes/codex-dual-path-full-chain-audit_v01_20260801-022457.md`. It preserves
the original `0 P0 / 12 P1 / 6 P2 / 1 P3` pre-fix findings and the independent
review's four additional P1s, then records the current disposition.

The isolated source lane is now `source-remediation-verified`:

- Plan: `plans/codex-shared-runtime-warm-switch_v01_20260731-230240.md`
- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-shared-runtime-20260731`
- Branch: `feature/codex-shared-runtime-20260731`
- Base: `a007dc712543c1410a26be980f2d838637c95c60`
- Bridge implementation: `4e66fbcb`
- Mobile implementation: `93ad516b`
- Native/Cloud notification hardening: `e54b8eca`
- Current source gate: `0 P0 / 0 P1 / 2 non-blocking P2 / 1 compatibility P3`

The two Codex origins now share durable identity, app-server status, exact
turn ownership, Action Broker requests, bounded incremental content, Mobile
SQLite staging and a single durable route. Bridge full tests passed 113 files /
2,264 tests; Mobile passed 2,876 tests with four environment smoke skips;
Functions passed 26 tests; the iOS Simulator build passed. Exact compatibility,
performance and caveat evidence is in the audit ledger.

This source result does not authorize or claim production 8765 replacement,
Desktop shared mode activation, Cloud deployment, OTA, IPA installation, phone
mutation or stable publication. Those remain explicit runtime/device/release
gates. Production and Desktop private mode were not changed by this task.

The earlier Stage 0–2 pilot documents remain useful historical evidence:

- Stage 0:
  `notes/codex-shared-runtime-stage0-deviation-ledger_v01_20260731-234929.md`
- Stage 2:
  `notes/codex-shared-runtime-stage2-pilot-evidence_v01_20260801-014302.md`

They established that the Desktop daemon needs a managed CLI under its exact
`CODEX_HOME`, UDS WebSocket compression must be disabled, and a newly created
thread needs a durable rollout before another connection can resume it. Their
older hard-stop and asymmetric first-responder statements are superseded for
source implementation by the Action Broker and writer-lease work above; they
remain relevant when planning the still-unperformed live Desktop/device gate.

## Active isolated lanes on 2026-07-31

- Coordinator fix lane:
  `fix/mobile-desktop-runtime-queue-20260731` in
  `ccpocket-worktrees/mobile-desktop-runtime-queue-fix-20260731`.
- User-directed conversation A:
  thread `019fb6c0-73c3-72e0-aaad-811126f41ca9`, branch
  `fix/parallel-bugfix-a-20260731`, worktree
  `ccpocket-worktrees/parallel-bugfix-a-20260731`.
- User-directed conversation B:
  thread `019fb6c1-6891-7050-be72-ab495e14940a`, branch
  `fix/parallel-bugfix-b-20260731`, worktree
  `ccpocket-worktrees/parallel-bugfix-b-20260731`.

All three lanes started from clean
`4fcdcd25ef96658a9137ddc4bb85a13c1b84f0a0`. Conversations A and B are
independent Codex threads, not coordinator subagents; they wait for direct user
assignment and must not edit the integration or another lane's worktree.

## Integrated source: delivery queue and Desktop detail facts

The verified source lane is in:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-desktop-runtime-queue-fix-20260731`
- Branch: `fix/mobile-desktop-runtime-queue-20260731`
- Base: `4fcdcd25ef96658a9137ddc4bb85a13c1b84f0a0`
- Verified code commit: `9cde3249`
- Evidence note:
  `notes/mobile-desktop-runtime-queue-fix_v01_20260731-140949.md`

This change separates ordinary online delivery, true local outbox, and the
Bridge-owned next-turn queue. It also projects source-scoped Desktop activity
and factual model/effort into detached details without provider resume, and
protects externally owned turns from stale Mobile model/speed writes. Mobile
full tests passed 2765 with 4 environment skips; Bridge single-worker full tests
passed 96 files / 1949 tests. It was fast-forwarded into
`integration/mobile-session-sync-v2-20260730` at source node `5bd82e7c`; it has
not yet been deployed, OTA-published, or accepted on a physical device.

## Verified provider-state implementation after repository convergence

The post-convergence provider-state task has passed its source, compatibility,
performance, build, independent audit, and branch-convergence gates:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730`
- Branch: `integration/mobile-session-sync-v2-20260730`
- Base: `c5b55b73ec479345a17bfd88f87cda4099db70dc`
- Accepted plan:
  `plans/mobile-provider-state-consistency_v01_20260731-005052.md`
- Verified code candidate:
  `583222be2bc77741896c416e7c82644052cb23c1`
- Accepted source/documentation commit:
  `a69f70d2b4e54b80ecb511d9f6af7ec771229a45`
- Tree-unchanged ancestry convergence:
  `856a0d6e0341c389ed64ebf812b861eb7527e1fe`
- Final audit:
  `notes/mobile-provider-state-consistency-audit_v01_20260731-060222.md`
- Independent review: `0 P0 / 0 P1 / 0 P2 / 1 P3`, approved for integration.

This task unifies visible activity and execution-host semantics for
Bridge-hosted and Codex Desktop/app-server-hosted conversations. It also fixes
history ordering, source identity, meaningful-progress loading, Bridge-owned
auto approval, two-stage queued-message acknowledgement, per-session protocol
errors, and read-only subagent discovery for detached Desktop conversations.

The authoritative development branch is now
`integration/mobile-session-sync-v2-20260730`. Source acceptance still does not
imply production Bridge replacement, OTA, IPA delivery, or physical-device
acceptance.

## Authoritative source baseline

The authoritative source and future multi-Agent baseline is:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730`
- Branch: `integration/mobile-session-sync-v2-20260730`
- Previous verified fallback:
  `fbfc528b81d998bf97cf8dd649c75b58d219af29`

Commit `fbfc528b` remains the pre-task fallback and restores the established Chinese-locale UI labels
`Plan On` / `Plan Off`. Its stable patch-id is identical to archived commit
`89e38f41`, and its focused localization tests and analyzer gate passed.

The primary repository checkout at
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat` remains a
non-development checkout. Create future work from the integration branch in an
absolute-path linked worktree.

## Repository convergence on 2026-07-31

The repository has been reduced to:

- 2 registered, clean worktrees;
- 6 ordinary local branch heads;
- 82 exact historical branch-tip refs under
  `refs/archive/ccpocket/pre-multi-agent-20260730/`;
- 3 recoverable dirty-worktree snapshots under
  `refs/archive/ccpocket/dirty-worktrees-20260731/`;
- 1 private historical-evidence tree under
  `refs/archive/ccpocket/private-evidence-20260731/`.

The three formerly protected dirty worktrees were reviewed before removal:

1. `feature/mobile-session-tools`
   - old persisted/modal Side Chat implementation;
   - superseded by official ephemeral threads, current compatibility adapters,
     and the non-modal auxiliary floating dock;
   - branch tip archived at
     `refs/archive/ccpocket/pre-multi-agent-20260730/feature/mobile-session-tools`;
   - exact tracked and untracked WIP archived at
     `refs/archive/ccpocket/dirty-worktrees-20260731/feature-mobile-session-tools-wip`.
2. `fix/mobile-comprehensive-v02-20260726`
   - old endpoint-bound identity/source sketch;
   - superseded by `BridgeDataSourceIdentity` and `conversation_sync_v2`;
   - unique VPN/readiness evidence was migrated to the private evidence tree;
   - branch tip and exact WIP have separate archive refs.
3. `feature/mobile-session-list-modes-20260730`
   - old list-mode WIP;
   - superseded by the current unread/important-session ordering,
     `conversation_sync_v2`, `systemError`, and durable nonresident states;
   - branch tip and exact 14-file WIP have separate archive refs.

No old transport implementation was mechanically merged. The only confirmed
missing behavior across the removed branch set was the Plan label patch now in
`fbfc528b`.

An unstarted stale cherry-pick sequencer for the five background-location
notification commits was also removed. Its `head` and `abort-safety` both
matched the clean old root HEAD, and all five commits remain reachable from:

`refs/archive/ccpocket/pre-multi-agent-20260730/feature/mobile-background-location-notify`

## Retained ordinary branches

- `integration/mobile-session-sync-v2-20260730`: authoritative development
  baseline.
- `main`: long-lived repository default; it is not the current integration
  target.
- `compat/artifact-download`: earlier explicit compatibility anchor.
- `backup/pre-upstream-1.67.4-20260719`: recorded historical rollback anchor.
- `fix/remote-altserver-signing`: independent deployed AltServer helper line.

The former `fix/mobile-session-continuity-hardening` line was audited
semantically before convergence. Its effective continuity/configuration/retry
behaviors were already present in the integration tree, while its persisted
modal Side Chat was explicitly superseded. Its exact tip remains at
`refs/archive/ccpocket/provider-state-consistency-20260731/fix/mobile-session-continuity-hardening`.
Do not fold or delete `fix/remote-altserver-signing` without a separate audit of
its independent deployed-helper evidence.

## Provider-state branch convergence on 2026-07-31

- The accepted task fast-forwarded the integration branch through
  `a69f70d2`.
- Commit `856a0d6e` records 15 secondary branch tips as ancestry only. The tree
  hash before and after the merge is exactly
  `a55955d4a6662361f6730995b07ea6e67c8d46e7`; no old transport or superseded
  Side Chat tree was reintroduced.
- All 16 deleted ordinary task branches have exact refs under
  `refs/archive/ccpocket/provider-state-consistency-20260731/`.
- Nine completed task worktrees were removed normally, without force, after
  verifying clean tracked state. Their reproducible build/dependency/index
  material accounted for about `4.43 GiB`.
- The repository now has two registered worktrees and five ordinary branch
  heads. Future tasks start from the integration branch, not from an archived
  task ref.

## Runtime and release boundary

Repository convergence did not rebuild, restart, or change the production
Bridge, OTA channel, IPA, physical phone, Mullvad, Tailscale, or Tailnet
forwarding.

The retired diagnostic-only LaunchAgent
`io.hututuo.ccpocket-data-plane-probe` was safely stopped because its program,
working directory, log, and dependency paths pointed into the worktree being
removed. Its former `127.0.0.1:18765` listener is gone. The production Bridge
remained PID `96010` on `127.0.0.1:8765` during the stop check.

The probe source, plist, README, final graceful-stop log, and integrity record
are preserved only in the private evidence ref. Those files include local
operational metadata and must not be pushed or published without redaction.

## Recovery

Restore an archived branch tip:

```bash
git branch <new-branch-name> \
  refs/archive/ccpocket/pre-multi-agent-20260730/<original-branch-name>
```

Inspect a dirty-worktree snapshot:

```bash
git stash show --stat \
  refs/archive/ccpocket/dirty-worktrees-20260731/<snapshot-name>
```

Restore one private evidence path into a clean task worktree:

```bash
git restore --source \
  refs/archive/ccpocket/private-evidence-20260731/pre-convergence-artifacts \
  --worktree -- <exact-path>
```

Never restore an entire snapshot over a dirty or active development worktree.
The private evidence namespace is local-only and must not be included in a
mirror push.

## Parallel A/B convergence and Mobile build 211

On 2026-07-31 the two user-directed lanes were consolidated into
`integration/mobile-session-sync-v2-20260730`:

- lane A `3b8612ce`: unread clearing/order stability and quota-ring retention;
- lane B `1f1e29a0`: durable preview recovery and canonical Desktop history;
- convergence merge `441f11af`: preserved ordinary-message ACK semantics,
  removed catalog SQLite N+1 reads, excluded internal subagent threads from
  the primary catalog, removed the 64-thread safe-metadata cutoff, bounded
  reconnect validation, and fenced source-changing cache reads;
- release-number commit `494f41f2`: Mobile `1.111.1+211`.

The targeted merged Mobile suite passed 226 tests, the affected cache suite
passed 24 tests, the v2 content-sync suite passed 21 tests, and Bridge passed
416 targeted tests plus TypeScript/native-helper builds. The previously run
full merged Mobile suite passed 2783 tests with four expected skips. Flutter
analyze reported no errors or warnings and 52 existing info diagnostics.

The unsigned arm64 AltStore input IPA is
`/Users/huyiyang/Documents/Downloads/CC-Pocket-1.111.1-build211-session-sync-converged-494f41f2-AltStore.ipa`.
It has SHA-256
`84cb862e4224f3da12267f36b577124b5163aabc0c526897aa02d018863a7f12`,
contains no embedded provisioning profile, and still uses placeholder Firebase
configuration. It was offered to one connected phone; a phone-side save or
install is a separate acceptance gate.

The production Bridge was not rebuilt, replaced, or restarted. Bridge source
changes in this convergence remain pending explicit user deployment command.
Both original worker worktrees remain clean and their sessions acknowledged
that this batch is closed and they should wait for later commands.

## Bridge compat.11 runtime

After explicit user authorization, production Bridge was rebuilt from the
clean integration HEAD `c64bf5ed` and switched to the versioned runtime
`1.69.5-compat.11.c64bf5ed`. LaunchAgent PID `11545`, the sole
`127.0.0.1:8765` listener, `/health`, `/version`, runtime entry, and unchanged
Tailscale Serve mapping were verified. The prior `compat.10-4fcdcd25` runtime
and the timestamped pre-switch plist remain the immediate rollback. No OTA was
published. See the deployment record and warm-switch investigation in
`PROJECT_INDEX.md`.

## New task worktree rule

Create every new code task from the authoritative branch with an absolute
target path:

```bash
git -C "/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat" \
  worktree add \
  "/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/<task>" \
  -b "<type>/<task>" \
  integration/mobile-session-sync-v2-20260730
```

Before editing, verify the new worktree path, branch, HEAD, and clean status.
