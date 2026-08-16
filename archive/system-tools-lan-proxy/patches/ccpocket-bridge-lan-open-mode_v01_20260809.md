# CC Pocket LAN open-mode alignment v01

Status: active

## Root cause

The production Bridge reports `BRIDGE_AUTH_MODE=open`, but the separate LAN
proxy retained `CCPOCKET_LAN_PROXY_TOKEN_SHA256`. HTTP health requests passed
through without a credential while WebSocket upgrades without `?token=` were
rejected with HTTP 401. Mobile therefore detected the Bridge as open and then
failed at the transport upgrade.

The proxy also treated `CCPOCKET_LAN_PROXY_INTERFACE=en0` as a preference. If
macOS momentarily omitted `en0` from `networkInterfaces()`, it selected the
first private address from a virtual `feth`/VM/VPN interface and rebound away
from Wi-Fi.

The first repair still unreferenced both the binding monitor and retry timer.
When DHCP changed the `en0` address, the listening socket briefly closed before
the replacement bind. With no referenced handle left, Node exited with status
0; `KeepAlive.SuccessfulExit=false` then correctly left the LaunchAgent stopped.
The phone retained its last committed 84% catalog milestone while the LAN
WebSocket disappeared.

## Change

- In development open mode, remove the LAN proxy token digest from the live
  LaunchAgent so its authentication contract matches Bridge `/health`.
- Treat the configured interface as authoritative. When `en0` has no suitable
  IPv4 address, keep the proxy process alive and wait instead of falling back
  to another interface.
- Keep the monitor and retry timer referenced so address-loss/rebind windows do
  not become a successful process exit.
- Preserve the production Bridge, shared Codex daemon, Tailscale route,
  upstream `127.0.0.1:8765`, port, session data and Mobile caches.

## Security boundary

Open mode permits devices that can reach the Mac on the same LAN to connect to
CC Pocket. It is suitable only for the explicitly requested development mode.
Returning to key or device-pairing mode must restore one consistent authority
at every entry point rather than leaving Bridge and its proxies with different
requirements.

## Rollback

Restore the pre-change helper and LAN proxy plist backup, then reload only
`com.ccpocket.bridge-lan-proxy`. Do not restart the production Bridge or shared
Codex app-server for this change.

Backup:

`/Users/huyiyang/Library/Application Support/ccPocket Bridge/backups/20260809-lan-open-mode`

## Verification

- Helper unit tests: 4/4 passed; `node --check` passed.
- Isolated candidate `192.168.124.219:18770`: HTTP 200 and no-token
  WebSocket 101.
- Production LAN proxy PID changed from 27484 to 91225 and now listens only on
  `192.168.124.219:8765`.
- Production no-token WebSocket returned 101; HTTP health returned 200.
- Two rebind intervals produced no listener or log change. The proxy remained
  on `en0`; stderr remained empty.
- The production Bridge PID stayed 51254 and `/readyz` remained ready.
- Tailscale TCP Serve on port 8765 remained mapped to `127.0.0.1:8765`.

Follow-up verification adds a child-process regression test that leaves the
configured interface unavailable and proves the helper remains alive until it
receives `SIGTERM`.
