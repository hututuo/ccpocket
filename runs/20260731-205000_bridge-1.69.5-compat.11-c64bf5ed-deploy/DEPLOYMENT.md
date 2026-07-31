# Bridge 1.69.5-compat.11.c64bf5ed deployment

Status: deployed and verified locally on 2026-07-31.

- Source worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730`
- Source branch/HEAD: `integration/mobile-session-sync-v2-20260730` / `c64bf5ed85de4df79530e97c0670abe7d504849d`
- Runtime: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.11-c64bf5ed`
- Runtime version: `1.69.5-compat.11.c64bf5ed`
- LaunchAgent: `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- Current PID after switch: `11545`
- Listener: one `127.0.0.1:8765` listener
- Health: `ok`
- Tailscale Serve: unchanged, `8765 -> 127.0.0.1:8765`
- CLI SHA-256: `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- WebSocket SHA-256: `a08578ef3cd2df1145d7e824258a847b962c13fac77583dc5e21fa4dd30e127b`

The candidate first started successfully on `127.0.0.1:18765`. The production
LaunchAgent was then switched with the existing `launchctl unload/load` pair.
The previous production runtime remains the immediate rollback:

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.10-4fcdcd25`

The pre-switch LaunchAgent backup is:

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260731-205000-compat10-to-compat11-c64bf5ed/com.ccpocket.bridge.plist.before`

Rollback: restore that plist, then use the same `launchctl unload` followed by
`launchctl load`, and recheck the single listener, `/health`, `/version`, and
the active `BRIDGE_CLI_ENTRY`.

No Shorebird release or patch was published. At the final local check the phone
had not yet reconnected (`clients=0`). The older `compat.9` runtime could not be
removed in this turn because the destructive cleanup command was rejected; it
is rebuildable and should be deleted after the current and rollback runtimes
have both been confirmed.
