# CC Pocket Compatibility Fork Project Index

| Path or ref | Type | Purpose | Deletable | Status |
|---|---|---|---|---|
| `plans/mobile-provider-state-consistency_v01_20260731-005052.md` | Active implementation plan | Unify Bridge/Codex-hosted state, source identity, ordering, loading progress, auto approval, and queued-message acknowledgements | No | `active`; implementation branch `fix/mobile-provider-state-consistency-20260731` at base `c5b55b73` |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-provider-state-consistency-20260731` | Isolated task worktree | Current post-convergence implementation and verification line | No while active | branch `fix/mobile-provider-state-consistency-20260731`; based on verified convergence tag |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730` | Authoritative source worktree | Baseline for all future CC Pocket code tasks | No | `active / clean`; branch `integration/mobile-session-sync-v2-20260730`, verified product commit `fbfc528b81d998bf97cf8dd649c75b58d219af29` |
| `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat` | Primary repository checkout | Shared Git object store and archive-ref access | No | `clean / detached` at `fbfc528b`; not a development worktree |
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
| `integration/mobile-session-sync-v2-20260730` | Authoritative |
| `main` | Long-lived default; not the current integration target |
| `compat/artifact-download` | Historical compatibility anchor |
| `backup/pre-upstream-1.67.4-20260719` | Historical rollback anchor |
| `fix/mobile-session-continuity-hardening` | Retain pending dedicated evidence extraction |
| `fix/remote-altserver-signing` | Retain as independent deployed helper line |

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
