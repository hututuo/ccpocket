# CC Pocket Bridge `df29b600` production deployment

## Result and scope

Status: **production switched successfully** on 2026-08-02 (Asia/Shanghai).

- Worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-dual-mode-compat-20260801`
- Branch / source HEAD: `fix/codex-dual-mode-compat-20260801` /
  `df29b6007829430290e44e0b3be0fdfae5ebcb56`
- Focused settings behavior: `bb277214`; metadata ownership correction:
  `df29b600`.
- Active runtime:
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.6-compat.12-df29b600`
- Retained direct rollback runtime:
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.6-compat.12-652867a8`
- Authorization was Bridge-only. Mobile, OTA, IPA, stable, Cloud, Desktop
  configuration, network configuration and user session data were not changed.

The fix preserves authoritative settings when an exact child rollout contains an
inherited parent `session_meta` in the bounded presentation parse. A truly
wrong persisted owner remains rejected; no cross-thread metadata adoption is
allowed.

## Candidate and focused settings gate

The candidate ran on isolated loopback `127.0.0.1:18770`, inheriting the live
LaunchAgent EnvironmentVariables. Only candidate entry, loopback host, port and
candidate public WebSocket URL were overridden. All metadata and protocol
probes explicitly received `CODEX_HOME`, shared daemon socket and source identity
from that plist; credentials were not recorded.

- Build and Darwin native helper succeeded.
- Targeted Bridge regressions (`sessions-index`, `conversation_sync_v2`,
  WebSocket): 3 files / 496 tests passed. The handoff's full source evidence was
  113 files / 2,277 tests passed.
- The production-held writer lease made candidate `/readyz` report
  `writer_lease_unavailable`; daemon control attachment, HTTP health and all
  read-only wire checks remained available, as expected for the isolated
  single-writer check.
- For provider `codex`, thread
  `019fa630-e195-7eb1-a856-9b6e95e6e494`, the staging resolver found the exact
  rollout, formal authoritative metadata returned the target, and all of model,
  reasoning effort, approval policy, sandbox mode and collaboration mode were
  present.
- Authenticated candidate wire smoke completed directory roots, v1 session list,
  v2 `sync_complete`, catalog/status/timeline events and an exact
  `codexSettingsSnapshotComplete=true` entry with all five settings fields.

## Switch and production verification

The pre-switch LaunchAgent plist was saved at:

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260802-652867a8-to-df29b600/com.ccpocket.bridge.plist.before`

The deployed snapshot is adjacent as `com.ccpocket.bridge.plist.deployed`.
The plist comparison proved that the only changed EnvironmentVariables value was
`BRIDGE_CLI_ENTRY`; shared daemon, source identity, credentials, URLs, allowed
directories, file transfer and session configuration were preserved. The shared
app-server socket existed before and after the Bridge-only switch.

- Active PID: `75949`; exactly one Bridge listener on `127.0.0.1:8765`.
- Runtime process path and LaunchAgent entry both identify `df29b600`.
- `/health`: `ok`, `applicationReady=true`.
- `/version`: `1.69.6-compat.12`.
- `/readyz`: `ready`, daemon mode; Action Broker ready/control-ready/non-degraded
  with writer lease held (authority generation `cab:9:9`).
- LAN proxy remained separate and unchanged on `192.168.124.67:8765` (PID
  `92135` at verification).
- Authenticated production smoke repeated the exact focused v2 complete snapshot
  and all five settings fields without protocol errors.
- The post-switch stderr window contained zero newly matched `error`, `failed`
  or `fatal` lines. Historical logs were not used as evidence for this startup.

Runtime SHA-256:

- `dist/cli.js`: `0e792e1258f32068b8cf9a4f9546540a88492cf9378d66696fcd035d46d2f65c`
- `dist/websocket.js`: `f90f71a098586ab46fbdc02396e6d30abdabbad708c15067c4345a48a1d9a999`
- `dist/sessions-index.js`: `aa4e0e8865abba31519a73188197e358d5400d6d72ca766a6cb1cc948ff0390a`
- `dist/local-features/conversation-sync-v2.js`:
  `d838ae18edf364d30962bfd4f6e558995d3de1ffce18ff647e147d4fe3ddb55c`

## Rollback and cleanup

To roll back, restore the saved `.before` plist, use the established user
LaunchAgent unload/load procedure from an external controller, then prove the
`652867a8` runtime entry, one loopback listener, healthy `/health` and ready
`/readyz`. Do not alter the shared app-server, Desktop environment, LAN proxy
or network configuration.

Removed after success: obsolete `402e0568` and `eb44e124` runtimes, rejected
`529cf431` staging, `df29b600` staging, candidate port `18770` and all temporary
candidate/metadata/smoke/plist/switch scripts. The runtime directory now holds
only `df29b600` and `652867a8`.

No physical phone was connected for this acceptance; this record proves the
local Bridge and real provider-data chain only, not phone UI or device behavior.
