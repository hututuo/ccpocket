# Mobile settings projection race investigation

Status: `source-fixed / targeted-verified / device-release-pending`

## Scope and live facts

- Worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-status-projection-stability-20260803`
- Branch: `fix/mobile-status-projection-stability-20260803`
- First continuity fix: `e92750fe3094351eae0a6c974d861091107a24b8`
- Sparse-catalog convergence fix: `c0c22101`
- Production Bridge observed during the investigation:
  `1.69.6-compat.15-b7bdeb7b`; `/health` and `/readyz` were healthy, daemon and
  Action Broker were ready, and the writer lease was held.
- Existing unsigned IPA:
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.111.1-build214-status-projection-stability-e92750fe-AltStore.ipa`.
  Its plist reports `1.111.1+214`, but both registered physical devices were
  unavailable to `devicectl`; the installed phone build and this new fix were
  not device-verified.

## Confirmed root cause

The symptom was not only a strict UI known/unknown gate. Four Mobile paths
project the same Codex catalog settings:

1. v2 catalog pages into SQLite;
2. v2 committed deltas into `SessionListCubit` memory;
3. legacy `recent_sessions` into SQLite;
4. legacy `recent_sessions` into `SessionListCubit` memory.

The SQLite v2 path already merged a later settings-sparse catalog entry with a
previous `codexSettingsSnapshotComplete=true` entry. The other three paths did
not consistently share that merge rule. In particular, the v2 event service
publishes the original wire entries after its transaction commits, and the
Cubit rebuilt its in-memory `RecentSession` directly from those sparse entries.
The legacy directory protocol also remains active during v2 startup and page
transitions, so it could overwrite both memory and SQLite after focused
hydration.

This produces the observed cycle:

`focused complete settings -> controls visible -> sparse catalog refresh ->
controls unknown -> cache reload or focused hydration -> controls visible`.

The Bridge itself already preserves a complete focused entry inside one
long-lived Bridge process. The Mobile-side convergence is still required after
app reconnects, Bridge restarts, cache restoration, and concurrent legacy/v2
startup traffic.

## Implemented correction

- `SessionCatalogCacheRepository.mergeIncompleteCodexSettings` is now the
  single merge rule used by persistent v2, persistent legacy, in-memory v2 and
  in-memory legacy paths.
- A complete incoming snapshot remains authoritative and can replace or clear
  settings. Only a sparse incoming snapshot inherits missing facts.
- Existing assistant-output ordering checkpoints remain monotonic; the old
  separate row decoder was removed, so the legacy write path still performs
  one bounded cache-row decode rather than adding a second scan.
- The previous source/authority safety fences remain intact. No mutation is
  enabled merely because cached settings stay visible.

## Mobile diagnostic events

The app now records content-free Talker events with deterministic opaque thread
and source tokens:

- `[settings_projection] event=sparse_catalog_preserved`
- `[settings_projection] event=legacy_catalog_preserved`
- `[settings_projection] event=source_changed`
- `[settings_projection] event=projection_suspended`
- `[settings_projection] event=settings_applied`
- `[status_projection] event=status_applied`

The fields record completeness, field-known booleans, effort/tier,
collaboration, actionability, authority presence and catalog readiness. They do
not log prompts, message bodies, paths, raw thread IDs or raw source
fingerprints. The logs are visible through the existing in-app Talker debug
screen or an attached device console.

## Verification

- `session_list_cubit_test.dart` plus
  `session_catalog_cache_repository_test.dart`: 84 tests passed.
- The earlier combined session/durable/chat suite after diagnostic changes:
  262 tests passed.
- Targeted analyze: 0 errors, 0 warnings; five pre-existing
  `prefer_initializing_formals` infos.
- `git diff --check`: passed.

The regression order covers complete settings followed by a legacy sparse
catalog, a v2 sparse catalog, and finally a new complete snapshot. Both memory
and SQLite must retain complete settings until the final authoritative update.

## Remaining gate

This is Dart-only Mobile source. Bridge, Swift/native code, Cloud, schema and
protocol fields are unchanged. A new Mobile OTA or IPA containing `c0c22101`
is required before the physical-phone symptom can be retested. Do not describe
build 214 at `e92750fe` as containing this follow-up.
