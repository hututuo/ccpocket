# CC Pocket Compatibility Fork Context

## 2026-08-08 compact bounded-history compatibility correction

The `fix/compact-bounded-history-20260808` line keeps Codex history on the
bounded `thread/turns/list` adapter after compact. The provider's exact
pre-materialization error remains an empty-history compatibility case, while
all other provider errors fail closed. A compact accepted before a private
resume's first history request invalidates the eager snapshot eligibility so
the next read returns to the bounded provider path.

The review correction also established a reusable paging rule: a terminal
Bridge error frame is insufficient when Mobile retains its local continuation
cursor. The correlated error must reach the paging state so automatic loading
stops, a visible Retry is rendered, and that explicit Retry reuses the same
opaque cursor. Regression tests must mock the bounded RPC actually invoked,
not a retired whole-thread method. This is source-only work; production,
deployment, OTA, IPA and physical-device gates remain untouched.

## 2026-08-08 external full-chain audit recheck

The current source-remediation line is
`fix/audit-report-remediation-20260808`, based on `03749002`. The external
WorkBuddy report was treated as a lead list rather than authority: its real
disconnect/status/heartbeat/canonical-read defects were fixed, while proposals
that would duplicate v2 recovery, broadcast device-local ACKs, or delete
compatibility/focus/Mirror paths were rejected against current call semantics.
Token registration now has bounded safe retry and durable Codex settings reuse
an active shared app-server client. Detailed disposition and open provider
capability gaps are in
`notes/audit-report-remediation_v01_20260808-060855.md`. Production, Cloud,
OTA, IPA, Desktop, network and phone state remain unchanged.

## 2026-08-08 LAN and readiness recovery

The current fix line is `fix/lan-readiness-recovery-20260808`, based on
`d2dd008b`. Live diagnosis separated two failures: the authenticated LAN proxy
still targeted the retired Wi-Fi address `192.168.124.67`, while the Bridge's
Action Broker heartbeat had silently cleared its in-memory writer lease and
never notified the runtime to retry. Mobile therefore either could not reach
the LAN endpoint or correctly stopped at 79% because `/readyz` returned
`action_broker_writer_unavailable`.

The system proxy now follows the current private `en0` IPv4 and the Bridge
runtime listens for an explicit lease-loss event, clears the stale generation,
and schedules the existing fenced reacquisition path. A same-runtime restart
restored production immediately without restarting the shared app-server;
permanent Bridge deployment and physical-phone acceptance remain separate.
Evidence: `notes/lan-and-readiness-recovery_v01_20260808-005605.md`.

## 2026-08-07 field retry and cache-rewind correction

The latest source correction on `fix/architecture-review-remediation-20260807`
separates upward older-turn paging from incomplete newest-turn repair, rejects
stale SQLite reads before they can rewind an open Codex or Claude screen, and
preserves visible live output while a provisional source or runtime binding is
being authoritatively confirmed. Two known unequal turn ids or source
fingerprints retain the existing isolation behavior. The detailed evidence is
in `notes/conversation-retry-cache-rewind_v01_20260807-094748.md`. The change is
Dart-only and source-verified; release and physical-device acceptance remain
separate gates.

## 2026-08-07 architecture Review remediation and independent upstream policy

The source-verified line is `fix/architecture-review-remediation-20260807`,
based on `b61597e9`, with implementation HEAD `1966a4a7`. Its plan is
`plans/full-architecture-review-remediation_v01_20260807-071715.md` and the
final source audit is
`notes/full-architecture-review-remediation_v01_20260807-083002.md`.

The external full-architecture Review was rechecked against real call
conditions. Shared-writer recovery, Codex retry, empty incomplete hot windows,
provider-read backoff and cross-runtime turn fencing are accepted fixes.
Claims that v1/v2/Mirror always compete, queue snapshots are duplicate
broadcasts, or current backpressure drops sequence frames are rejected pending
contrary runtime evidence. The project now selectively absorbs useful upstream
commits instead of preserving full official replay compatibility; CC Pocket's
own old/new Mobile and Bridge compatibility remains mandatory. Production,
OTA, IPA, Cloud, Desktop and device state are not changed by this source plan.
The verified implementation selectively absorbs upstream long-session
performance work, adds real Codex failed-message retry, restores incomplete
hot windows, bounds provider-read failure retries and validates preserved
streaming by active turn. Bridge passed 114 files / 2,323 tests; Mobile passed
2,925 tests with four skips, and analyze has 0 errors / 0 warnings / 52 infos.
The session-sync benchmark stayed below 64 KiB per frame and completed the
synthetic 10,000-session initial sync at p95 95.68 ms on this Mac.

## 2026-08-06 conversation sync stability program

The active investigation and implementation plan is
`plans/conversation-sync-stability_v01_20260806-160058.md` on
`fix/conversation-sync-stability-20260806`, based on production source
`98d48eccddd6e52ef4733c27e11a8ee5fe493ac3`.

This program prioritizes real open/load/retry/live-cache continuity over code
beautification or new abstractions. It must trace every loading and retry action
from UI to provider and back through SQLite, prevent stale snapshots from
overwriting live content, persist accepted new messages, keep visible content
stable while runtime mutation authority reconciles, and provide a bounded
latest-turn path for very large Codex rollouts. Luna Max completed the first
read-only open exploration and the root task accepted the six primary chain
findings. The first implementation slice is now recorded as `bdf62a5f`
(Bridge bounded history/live fallback), `057ad4dd` (Mobile cache/runtime/retry
continuity), and `d2bf80cc` (visible retry and durable scroll behavior). The
detailed evidence and explicitly open protocol gaps are in
`notes/conversation-sync-stability-audit_v01_20260806.md`. Production Bridge,
release task, OTA/IPA, stable and physical device remain untouched until
separately authorized.

## 2026-08-04 first-open settings prewarm and ACK projection

The source-verified follow-up is in
`fix/mobile-toolbar-batch-settings-20260804` from base `83c0cf56`:

- Bridge `5120b478`: prewarms focused, recent-five and special Codex settings
  with concurrency 3, queue 32, five-second timeout and generation/epoch fences.
- Mobile `882b02ff`: applies valid durable model/effort/speed ACKs immediately,
  preserves rollback on malformed ACKs, and does not hide model/effort merely
  because service tier is missing.

Bridge passed 118 focused protocol tests and build; Mobile passed 217 related
tests with 0 analyzer errors/warnings and two existing infos. Independent Luna
Max review concluded LGTM. Details are in
`notes/mobile-settings-projection-race_v02_20260804-095340.md`. Production
Bridge, owner OTA, IPA, device, Cloud, Desktop and stable remain unchanged.

## 2026-08-03 Mobile Codex settings projection convergence

The active source correction is `c0c22101` on
`fix/mobile-status-projection-stability-20260803`, following the route and
runtime continuity correction `e92750fe`. The confirmed intermittent
`未知 · 等待同步` cycle was caused by split merge semantics: focused settings
could be complete in SQLite, while a later settings-sparse v2 event or legacy
`recent_sessions` response replaced the in-memory projection; the legacy write
path could also downgrade SQLite. All four v2/legacy and memory/SQLite paths now
use one sparse-versus-complete merge rule. Complete snapshots remain
authoritative; sparse refreshes preserve missing known settings without
granting mutation authority.

Content-free correlated diagnostics now cover catalog preservation, source
changes, projection suspension, applied settings and applied runtime status.
The source and focused tests pass, but no physical device was available to
confirm the installed build. Production Bridge remains
`1.69.6-compat.15-b7bdeb7b`; it was not changed. Full details and the phone
acceptance boundary are in
`notes/mobile-settings-projection-race_v01_20260803-121147.md`.

## 2026-08-02 authorized task-contact boundary

The user has authorized only the persistent release task
`019f8e9d-2490-79c0-817c-87e3eb93ea2f`, and it may be contacted only when the
user explicitly asks to hand off a build, deployment or release. The historical
task `019f8ff9-0945-72a3-a29e-c17df6f112e5` is not an authorized coordinator;
do not send it reports, commands or corrections. Ordinary development and
review results stay in the current task and are reported directly to the user.

## 2026-08-02 canonical current worktree and Codex project policy

All source branches registered during the July 30 to August 2 integration are
linear ancestors of the new canonical source line:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current`
- Branch: `integration/ccpocket-current`
- Starting source: `e4583b50` (`1.111.1+214`)
- Project-policy correction: `f1d18745`
- Recovered process-disclosure change: `0a374184`

The dated `mobile-tiered-session-sync-20260730` worktree is no longer the
authoritative development baseline and was removed after its dirty project
configuration was archived as `ec485ba3` and every branch tip received a
local archive ref. The persistent release task still records that obsolete
cwd in its history, but a task cwd or project selector is never source
authority. Every future handoff must explicitly use the current worktree,
branch and full HEAD; if a runner cannot change to that path it must stop
before building or publishing.

The repository previously combined `AskForApproval=Never` background turns
with project rules that marked Node, npm, Git and other commands as `prompt`.
Those commands therefore failed before process creation even when the user had
selected Full Access. The project no longer fixes `approval_policy` or adds
mandatory prompt rules. Command approval and sandboxing now follow the current
Codex task's Normal / Full Access selection. Narrow allow rules remain only for
routine local inspection, build and test commands; they do not reduce Full
Access. Release authorization and product deployment gates remain workflow
requirements, not execpolicy overrides.

The only uncommitted source found during worktree cleanup was a three-file
process-disclosure improvement in the old parallel lane. It was archived as
`refs/archive/ccpocket/worktree-cleanup-20260802/parallel-bugfix-a-process-disclosure-wip`,
ported onto the current line, and verified by 14 Widget tests plus targeted
analysis. Expanded current progress now retains its latest-tool row and shows
an explicit expanded/collapsed icon.

The cleanup left exactly two registered checkouts: the detached primary Git
store and the `current` development worktree. Seventeen archive refs preserve
all removed tips and both dirty snapshots. Large rebuildable worktree,
candidate and dependency material was moved to the recoverable Trash folder
recorded in `notes/worktree-and-project-policy-cleanup_v01_20260802-223500.md`;
production Bridge files, user session data, VPN/Desktop configuration and the
two current/rollback IPA files were not removed.

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

## Business-logic audit convergence on 2026-08-03

The reviewed audit reports were reconciled against the latest Mobile source
baseline `b28cae1346b11d543fd51a2350a19eafdcca9a72`, not the older dirty
`integration/ccpocket-current` checkout. The source candidate is the isolated
branch `fix/settings-runtime-consistency-20260803`.

The candidate now contains five behavior units:

- preserve indexed Plan/default collaboration mode when a new Mobile resume
  request omits an explicit override;
- wait for private Codex `thread/settings/update` and label the additive ACK as
  `durable` or `runtime_only` instead of racing an authoritative snapshot;
- tolerate bounded malformed Mirror inline items while failing closed on an
  incomplete patch revision and retaining the original watch through a scoped
  snapshot reset;
- reconcile Subagent activity revisions to authoritative list snapshots only
  while details are visible, with target/generation fences and old-Bridge
  fallback;
- retain the accepted implementation and compatibility plan at
  `plans/business-logic-remediation_v01_20260803-151723.md`.

Integrated evidence: three focused Bridge tests passed; Bridge TypeScript and
native helper build passed; 123 combined Mobile tests passed; targeted analyze
reported no errors or warnings and only two pre-existing info diagnostics;
format and `git diff --check` passed. No production, OTA, IPA, Cloud, stable or
physical-device gate was exercised.

The audit's Side Chat wording was narrowed: the active UI and Bridge registry
use the ephemeral path. Persisted protocol/parser/pane files are legacy
artifacts, not proof of a currently registered competing product path. Do not
re-register persisted Side Chat or delete its compatibility artifacts before a
supported-old-Bridge matrix is complete.

At the final live check, production remained
`1.69.6-compat.15-b7bdeb7b`. Its process and existing loopback/LAN proxy
listeners were alive, but `/readyz` returned HTTP 503 with
`shared_runtime_control_unavailable` and
`action_broker_writer_unavailable`. A future release task must restore and
verify daemon control plus Action Broker mutation before claiming the backend
or phone settings path is accepted. This source task did not restart it.

The first release attempt restored the managed app-server daemon successfully
but exposed a branch-convergence omission: the Mobile-derived candidate did not
contain the already-proven production Bridge commits for canonical durable
`projectPath` resolution and atomic full-settings preservation. The candidate
therefore failed the real mutation gate with
`codex_durable_thread_settings_not_found` and was safely rolled back without a
settings side effect.

The missing behavior is now integrated as `c31dbd87` and `314ceb47`. Focused
Bridge regression tests passed 9/9, TypeScript/native helper build passed, and
the worktree remained clean after documentation. Future release handoffs must
compare both the latest Mobile branch and the latest deployed Bridge behavior;
neither branch alone is a complete integration baseline.
