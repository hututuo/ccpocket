# CC Pocket LAN proxy dynamic-IP repair v01

Status: active

## Root cause

The production Bridge intentionally listens on `127.0.0.1:8765` because
Tailscale TCP Serve owns the Tailnet address on the same port. LAN access is a
separate authenticated proxy. That proxy's plist fixed its listener to
`192.168.124.67`; the Mac's current `en0` address is
`192.168.124.219`. Launchd therefore recorded 17,722 attempts, and the helper
exited each time with `EADDRNOTAVAIL`.

## Change

- `CCPOCKET_LAN_PROXY_HOST=auto`
- `CCPOCKET_LAN_PROXY_INTERFACE=en0`
- Resolve only private, non-loopback IPv4 addresses.
- Reconcile every five seconds and rebind when the Wi-Fi address changes.
- Wait in-process when Wi-Fi has no suitable address instead of crashing and
  generating an unbounded restart log.
- Preserve the existing token SHA-256, upstream `127.0.0.1:8765`, port 8765,
  Bridge API key and Tailscale configuration.

Installed paths:

- Helper: `/Users/huyiyang/Library/Application Support/ccPocket Bridge/helpers/ccpocket-bridge-lan-proxy.mjs`
- LaunchAgent: `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge-lan-proxy.plist`

## Verification

- `node --test`: 3/3 passed.
- `node --check`: passed.
- Candidate on `192.168.124.219:18769`: HTTP health 200, missing-key WebSocket
  401, correct-key WebSocket opened.
- Installed LaunchAgent: running as PID 27484 on
  `192.168.124.219:8765`; stderr is empty.
- Installed helper SHA-256 matches the tracked source:
  `0e9c607c408068da94aec992326b521931db572a992c30c042a35b638fdcf868`.

## Rollback

Follow `backups/20260808-005138_ccpocket-lan-proxy-dynamic-ip/README.md`.
Rollback restores the old fixed address and is therefore unsuitable unless the
Mac again owns `192.168.124.67`.
