# CC Pocket Compatibility Fork Context

## Authoritative source baseline

The authoritative source and future multi-Agent baseline is:

- Worktree:
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730`
- Branch: `integration/mobile-session-sync-v2-20260730`
- Verified product commit:
  `fbfc528b81d998bf97cf8dd649c75b58d219af29`

Commit `fbfc528b` restores the established Chinese-locale UI labels
`Plan On` / `Plan Off`. Its stable patch-id is identical to archived commit
`89e38f41`, and its focused localization tests and analyzer gate passed.

The primary repository checkout at
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat` is a clean,
detached checkout of the same verified product commit. Do not develop directly
there. Create a new absolute-path linked worktree from the integration branch.

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
- `fix/mobile-session-continuity-hardening`: retained because its mixed,
  unique continuity evidence still requires a dedicated extraction decision.
- `fix/remote-altserver-signing`: independent deployed AltServer helper line.

Do not delete the last two task branches without a separate audit of their
remaining unique operational evidence.

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
