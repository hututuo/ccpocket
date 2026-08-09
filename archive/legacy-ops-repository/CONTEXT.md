# ccPocket Context

This project records installation, service configuration, diagnostics, and rollback information for the user-level ccPocket Bridge on macOS.

## Current State

- 2026-07-15: Prepared a sanitized Shadowrocket correction block that keeps the Tailscale CGNAT range inside rule processing and makes Apple core domains/IP space direct. It intentionally excludes the exposed MITM private CA material. Record: `configs/shadowrocket-tailscale-apple-direct_v01_20260715-173153.conf`.
- 2026-07-15: Confirmed why ccPocket traffic over Shadowrocket never reached its `TAILSCALE` rule: the active configuration put `100.64.0.0/10` in `bypass-tun` (and `skip-proxy`), excluding the range before rule matching. The Bridge and official Tailscale path remain healthy. Client-side removal of those exclusions and reconnection are pending validation. Record: `notes/tailscale-shadowrocket-routing_v01_20260715-142300.md`.
- The Bridge is registered as the user LaunchAgent `com.ccpocket.bridge`.
- Its global configuration file is `~/Library/LaunchAgents/com.ccpocket.bridge.plist`.
- The service listens on port `8765` and is launched through `npx --yes @ccpocket/bridge@latest`.
- The active package resolved by `@latest` is `@ccpocket/bridge` 1.65.0.
- The 2026-07-14 setup refresh rewrote an identical plist, disconnected while unloading its own transport, and was completed by manually loading and starting the validated plist. It is tracked in `patches/bridge-setup_v01_20260714-075945.md`.

## Handoff

- Read `PROJECT_INDEX.md` before changing the Bridge service.
- Back up the active plist before rerunning setup or uninstalling the LaunchAgent.
- Runtime logs are global temporary files at `/tmp/ccpocket-bridge.log` and `/tmp/ccpocket-bridge.err`.
