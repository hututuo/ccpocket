# CC Pocket Bridge production deployment

## Scope

- Deployment window: 2026-08-02 00:38-00:41 Asia/Shanghai.
- Source worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-dual-mode-compat-20260801`.
- Branch: `fix/codex-dual-mode-compat-20260801`.
- Source HEAD: `652867a81ccf23246df50dbafe2fd49cd4ac4f1c`.
- Behavior commit: `0848fd91b569a1c91508fcc84b4cffdd6d672314`.
- Authorized change: build and select the new versioned Bridge runtime.
- Explicitly excluded: Mobile source, OTA, IPA, stable, Cloud, Desktop `CODEX_HOME`, VPN, Tailnet, user sessions and phone data.

## Active runtime

- Runtime path: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.6-compat.12-652867a8`.
- Reported version: `1.69.6-compat.12`.
- Reported Git commit: `652867a8`.
- Process: PID `64563`.
- Listener: exactly one `127.0.0.1:8765` listener.
- `/health`: `ok`, `applicationReady=true`.
- `/readyz`: ready in daemon mode.
- Action Broker: ready, control-ready and writer lease held; observed authority generation `cab:8:8`.
- The existing LAN proxy remained active as PID `92135` on `192.168.124.67:8765`.

Only `BRIDGE_CLI_ENTRY` in `~/Library/LaunchAgents/com.ccpocket.bridge.plist`
was changed. Host, port, public URL, artifact URL, allowed directories,
`CODEX_HOME`, daemon socket and source identity were preserved. No credential is
stored in this record.

## Integrity

- `dist/cli.js`: `0e792e1258f32068b8cf9a4f9546540a88492cf9378d66696fcd035d46d2f65c`.
- `dist/websocket.js`: `f90f71a098586ab46fbdc02396e6d30abdabbad708c15067c4345a48a1d9a999`.
- Native file-browser helper: `201a06a4696defcc2d2f70073100d81ddd1f8e88b7ed2c8902f4022398f3c765`.

## Verification

- Bridge full test run: 113 files and 2,271 tests passed in single-worker mode.
- Focused WebSocket tests: 290/290 passed.
- Focused controller and v2 tests: 120/120 passed.
- Mobile authority and durable-preview regressions: 201/201 passed.
- TypeScript build, native helper build and `git diff --check` passed.
- Authenticated production WebSocket smoke passed for session list, recent/v2 catalog and file-browser roots/list.
- Local `/version`, `/health` and `/readyz` probes passed after the runtime switch.
- LaunchAgent, process path, version and the single listener all identify the new runtime.

Historical logs still contain an older `eb44e124` auto-rename Git-context
failure and an optional Claude model-catalog warning for a missing API key.
Neither was produced by this deployment and neither blocks the active Codex
runtime.

## Rollback

- Retained rollback runtime: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.6-compat.12-eb44e124`.
- Pre-deployment LaunchAgent backup: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260802-eb44-to-652867a8/com.ccpocket.bridge.plist.before`.
- Deployed LaunchAgent snapshot: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260802-eb44-to-652867a8/com.ccpocket.bridge.plist.deployed`.

Rollback must be initiated from an external controlling shell rather than from
a conversation whose transport depends on this Bridge. Restore the exact
`.before` plist, stop the current user LaunchAgent using the project's existing
registration method, wait at least two seconds, then load the restored plist.
Verify that `/version` reports the `eb44e124` runtime, `/health` is healthy and
there is exactly one `127.0.0.1:8765` listener. Do not change VPN,
`CODEX_HOME`, routes or credentials during rollback.

## Cleanup and remaining gate

Candidate staging and read-only smoke files under `/private/tmp` were removed,
reclaiming approximately 275 MiB. The active runtime and one rollback runtime
are retained. No IPA was built or changed.

The remaining acceptance gate is a physical-phone check after reconnecting:
leave and reopen a shared conversation, confirm model and reasoning-effort
facts, change plan mode, and stop an active turn without waiting for a later
Desktop transcript event.
