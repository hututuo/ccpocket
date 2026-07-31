# CC Pocket Compatibility Fork Project Index

| Path or ref | Type | Purpose | Deletable | Status |
|---|---|---|---|---|
| `ccpocket-worktrees/mobile-desktop-runtime-queue-fix-20260731` | Integrated coordinator worktree | Fix delivery queue semantics and Desktop detail facts | Keep until release handoff is confirmed | branch `fix/mobile-desktop-runtime-queue-20260731`; code `9cde3249`; source record `5bd82e7c`; fast-forwarded into integration |
| `ccpocket-worktrees/parallel-bugfix-a-20260731` / thread `019fb6c0-73c3-72e0-aaad-811126f41ca9` | Integrated Codex lane A | Unread/order stability and quota-ring retention | No; preserve for later commands | clean tip `3b8612ce`; semantically merged by `441f11af`; worker acknowledged convergence and is waiting |
| `ccpocket-worktrees/parallel-bugfix-b-20260731` / thread `019fb6c1-6891-7050-be72-ab495e14940a` | Integrated Codex lane B | Durable preview recovery and canonical Desktop history convergence | No; preserve for later commands | clean tip `1f1e29a0`; ancestry and follow-up corrections included by `441f11af`; worker acknowledged convergence and is waiting |
| `notes/mobile-desktop-runtime-queue-fix_v01_20260731-140949.md` | Integrated source audit note | Separate ordinary delivery/local outbox/Bridge queue and restore Desktop detail status/effort facts | No | `integrated-source-verified`; Mobile 2765 + 4 skipped, Bridge 1949; deploy/OTA/device gates open |
| `plans/mobile-provider-state-consistency_v01_20260731-005052.md` | Accepted implementation plan | Unify Bridge/Codex-hosted state, source identity, ordering, loading progress, auto approval, and queued-message acknowledgements | No | `accepted`; code candidate `583222be`; independent audit approved |
| `notes/mobile-provider-state-consistency-audit_v01_20260731-060222.md` | Final audit | Original-requirement ledger, two audit rounds, compatibility, performance, builds, branch mapping, and remaining release/device gates | No | `accepted`; `0 P0 / 0 P1 / 0 P2 / 1 P3` |
| `refs/archive/ccpocket/provider-state-consistency-20260731/*` | Exact task branch-tip archive | Preserve all 16 deleted provider-state, performance, compatibility, and worker branch tips | No until later archive-retention audit | `16 refs`; ordinary branches deleted only after ancestry registration |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730` | Authoritative source worktree | Baseline for all future CC Pocket code tasks | No | branch `integration/mobile-session-sync-v2-20260730`; A/B convergence `441f11af`; Mobile build bump `494f41f2` |
| `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.111.1-build211-session-sync-converged-494f41f2-AltStore.ipa` | Current unsigned AltStore input IPA | Physical-phone build containing the converged A/B frontend | Keep | 24,001,254 bytes; SHA-256 `84cb862e4224f3da12267f36b577124b5163aabc0c526897aa02d018863a7f12`; offered to one connected phone; phone save not yet confirmed |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat` | Primary repository checkout | Shared Git object store and archive-ref access | No | non-development checkout; aligned to the final verified integration tag at closeout |
| `refs/archive/ccpocket/pre-multi-agent-20260730/*` | Exact historical branch-tip archive | Restore deleted ordinary local branches without keeping them active | No until a later archive-retention audit | `82 refs`; includes the newly archived old root, comprehensive, and list-mode tips |
| `refs/archive/ccpocket/dirty-worktrees-20260731/feature-mobile-session-tools-wip` | Stash-format WIP archive | Preserve the old root tracked changes and Side Chat source/tests | No | commit `f63daba604ef6b5cdfb1df0b2c068860b93ced44`; reviewed as superseded, not merged |
| `refs/archive/ccpocket/dirty-worktrees-20260731/fix-mobile-comprehensive-v02-20260726-wip` | Stash-format WIP archive | Preserve the old comprehensive-remediation tracked source sketch | No | commit `d6c2d8447846bd0ebaf5ed3f9d578c7bec908233`; reviewed as superseded, not merged |
| `refs/archive/ccpocket/dirty-worktrees-20260731/feature-mobile-session-list-modes-20260730-wip` | Stash-format WIP archive | Preserve the old list-mode 14-file worktree delta | No | commit `ff20dee4791a3197ea8ccf76f1dae672f61ffc1b`; reviewed as superseded, not merged |
| `refs/archive/ccpocket/private-evidence-20260731/pre-convergence-artifacts` | Private local evidence tree | Preserve unique plans, notes, patch records, selected visuals, one AltServer rollback binary, network diagnostics, and retired probe evidence without keeping a dirty worktree | No; do not push | commit `3878f9e4131506bc47679d3398a44aa5204dcb0b`, 89 files, about 3 MiB |
| `refs/archive/ccpocket/private-evidence-20260731/pre-convergence-artifacts:runs/20260728-085947_tailnet-data-plane-probe/ARCHIVE.md` | Diagnostic retirement record | Record the exact local-only probe stop, integrity hashes, and recovery boundary | No | probe job and port 18765 absent; production Bridge PID `96010` and port 8765 unchanged at verification |
| `fbfc528b81d998bf97cf8dd649c75b58d219af29` | Narrow compatibility fix | Restore established `Plan On` / `Plan Off` labels in the Chinese locale | No | focused localization tests 6/6 and 1/1 passed; targeted analyzer clean; generated localization stable; diff check passed; stable patch-id equals archived `89e38f41` |

## Convergence disposition

- Initial retained historical material:
  `147348 KiB` across `backups/`, `runs/`, `patches/`, `plans/`, and `notes/`.
- Material selected for private archival before Git compression:
  `3084 KiB`.
- Reproducible or superseded material removed:
  `144264 KiB` (about `140.9 MiB`), principally an expanded old
  `Runner.app`, obsolete installers, duplicate Bridge `dist` trees, old plist
  copies, duplicate AltServer helpers, installer logs, and superseded visual
  captures.
- Retained visual evidence is limited to four selected regression references.
- The retained AltServer binary is the prior `96f1368` helper only; the current
  duplicate and the older duplicate were removed.
- Sensitive/private operational evidence remains only in the local hidden ref
  and is not part of the integration branch.

## Current ordinary branch heads

| Branch | Disposition |
|---|---|
| `integration/mobile-session-sync-v2-20260730` | Authoritative provider-state integration line |
| `fix/mobile-desktop-runtime-queue-20260731` | Fast-forwarded into the integration line; retain through release handoff |
| `fix/parallel-bugfix-a-20260731` | User-directed isolated lane A; waiting for task |
| `fix/parallel-bugfix-b-20260731` | User-directed isolated lane B; waiting for task |
| `main` | Long-lived default; not the current integration target |
| `compat/artifact-download` | Historical compatibility anchor |
| `backup/pre-upstream-1.67.4-20260719` | Historical rollback anchor |
| `fix/remote-altserver-signing` | Retain as independent deployed helper line |

## Provider-state convergence disposition

- Source and audit fast-forward: `a69f70d2`.
- Tree-unchanged ancestry merge: `856a0d6e`; before/after tree
  `a55955d4a6662361f6730995b07ea6e67c8d46e7`.
- Exact archived task refs: `16`.
- Normally removed task worktrees: `9`.
- Normally deleted ordinary task branches: `16`.
- Reproducible worktree material removed: `4,645,120 KiB`, about `4.43 GiB`.
- Remaining ordinary branches: `5`.
- Production Bridge, OTA, IPA, phone data, VPN state, and Tailnet forwarding
  were not changed by the convergence.

## Verification boundary

- Both registered worktrees were clean after convergence.
- The old list-mode and comprehensive worktrees were removed normally, without
  force.
- The old root checkout was detached only after its branch tip, source WIP,
  and private evidence were independently archived.
- Production Bridge, OTA, IPA, phone data, VPN state, and Tailnet forwarding
  were not changed.
- This convergence task validates repository state and the narrow Plan label
  patch. It does not replace physical-device, OTA, IPA, or production sync
  acceptance for unrelated features.
