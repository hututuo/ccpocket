# CC Pocket Compatibility Fork Context

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

## Pending integration: delivery queue and Desktop detail facts

The isolated source candidate is in:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-desktop-runtime-queue-fix-20260731`
- Branch: `fix/mobile-desktop-runtime-queue-20260731`
- Base: `4fcdcd25ef96658a9137ddc4bb85a13c1b84f0a0`
- Verified code commit: `9cde3249`
- Evidence note:
  `notes/mobile-desktop-runtime-queue-fix_v01_20260731-140949.md`

This candidate separates ordinary online delivery, true local outbox, and the
Bridge-owned next-turn queue. It also projects source-scoped Desktop activity
and factual model/effort into detached details without provider resume, and
protects externally owned turns from stale Mobile model/speed writes. Mobile
full tests passed 2765 with 4 environment skips; Bridge single-worker full tests
passed 96 files / 1949 tests. It has not yet been merged, deployed, OTA-published, or
accepted on a physical device.

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
