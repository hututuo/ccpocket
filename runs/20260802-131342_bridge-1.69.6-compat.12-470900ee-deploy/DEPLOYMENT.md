# CC Pocket Bridge `470900ee` connection-auth production deployment

## Result and scope

Status: **production switched successfully** on 2026-08-02 (Asia/Shanghai).

- Worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/optional-bridge-connection-auth-20260802`
- Branch / source HEAD: `feature/optional-bridge-connection-auth-20260802` /
  `470900ee8f9259f600b6078aa8fba2619fba47c8`
- Bridge behavior commit: `e6e559d0fdf61388ef5363005ab9714a26a89152`
- Active runtime: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.6-compat.12-470900ee`
- Direct rollback runtime: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.6-compat.12-df29b600`

Only Bridge runtime and its existing LaunchAgent were in scope. Mobile OTA,
IPA, stable, Cloud, Desktop configuration, network configuration and user
session data were not changed.

## Authentication behavior and candidate gate

The Bridge now treats `BRIDGE_API_KEY` as the saved connection credential and
`BRIDGE_REQUIRE_API_KEY` as the explicit authentication switch. Production is
set to `BRIDGE_REQUIRE_API_KEY=1`; it was not changed to trusted-LAN opt-out.
The connection credential remains separate from file mutation/password/Face ID
step-up authorization.

The candidate ran on `127.0.0.1:18771`, with all production EnvironmentVariables
derived from the current LaunchAgent plist. Only candidate entry, loopback host,
port, candidate public WebSocket URL and the intended auth-on setting differed.
No credential, token, URL or request content was recorded.

- TypeScript and Darwin native helper build passed.
- Release-run authentication regression: 5 files / 377 tests passed. The
  handoff's complete source evidence was 114 files / 2,295 tests passed.
- `/health.bridgeAuthentication` reported `required=true`, `scheme=api_key`.
- Missing and wrong WebSocket credentials both received HTTP 401 at upgrade.
- A correct credential completed authenticated directory roots, v1 session list,
  v2 catalog/status/timeline events and `sync_complete`.
- Candidate daemon/control attachment passed. Its writer lease was unavailable
  only because the production Bridge held the same-source single-writer lease;
  this expected candidate state was rechecked after switch.

## Production switch and verification

The pre-switch complete plist is retained at:

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260802-df29b600-to-470900ee/com.ccpocket.bridge.plist.before`

The deployed plist snapshot is adjacent as `com.ccpocket.bridge.plist.deployed`.
A structured plist comparison proved that exactly two values changed:
`BRIDGE_CLI_ENTRY` and the new `BRIDGE_REQUIRE_API_KEY=1`; the existing API key,
host/port, CODEX_HOME, daemon socket/source identity, public/artifact URLs,
allowed dirs, file-transfer and session configuration were preserved.

- Active PID: `61277`; exactly one Bridge listener on `127.0.0.1:8765`.
- LaunchAgent and process path both identify runtime `470900ee`.
- `/health`: `ok`, `applicationReady=true`, authentication required with API-key
  scheme.
- `/version`: `1.69.6-compat.12`.
- `/readyz`: `ready`, daemon mode; Action Broker ready/control-ready/non-degraded
  with writer lease held (authority generation `cab:10:10`).
- Shared app-server socket remained present before and after the switch.
- Existing LAN proxy remained separate and unchanged at `192.168.124.67:8765`
  (PID `92135` during verification).
- Production repeated the missing-key 401, wrong-key 401 and correct-key
  authenticated directory/v1/v2 smoke successfully.

Runtime SHA-256:

- `dist/cli.js`: `fb7a5d9e8c9aba1e2ae76cd6fe750c432f476cc97b108d98a8e61d6ce22bcfd1`
- `dist/websocket.js`: `8427c1e29d147d799e7166019f57dbf29ecb142a60ac1794a116c2282bfd81b4`
- `dist/bridge-connection-auth.js`: `f62d2778f664ee2e71a10a254008dbc51835962a0e38a4b85971ad4f6c4ffd4c`

The shared stderr file contains predecessor-history diagnostics and was not
treated as evidence for this launch. No production health, readiness, auth or
protocol gate failed after switch.

## OTA gate and cleanup

Owner OTA was independently checked but not published. Shorebird still lists
only iOS base `1.110.1+208` (release `739446`); current source is
`1.111.1+212`, and the cloud-base-to-current boundary contains Swift/native and
pubspec changes. The current release environment also had no matching app-id
variable or readable RSA signing material. Patching build 208 is forbidden.
The existing build-208 Patch 1 (`572749`) remains on `owner`; no stable patch
was present or changed.

Removed after success: superseded `652867a8` runtime, candidate port 18771,
candidate staging and all temporary launch/auth/smoke/plist/switch probes. Only
the active `470900ee` runtime and direct rollback `df29b600` remain. No physical
phone was used during this server deployment; phone acceptance requires the
future build-212 base plus owner patch and a complete app restart.
