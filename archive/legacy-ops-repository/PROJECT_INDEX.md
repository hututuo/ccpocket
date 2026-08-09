# ccPocket Project Index

| Path | Created | Updated | Type | Purpose | Deletable | Status |
|---|---|---|---|---|---|---|
| `configs/shadowrocket-tailscale-apple-direct_v01_20260715-173153.conf` | 2026-07-15 17:31 | 2026-07-15 17:31 | Sanitized client config | Replacement blocks for Tailscale routing and Apple-direct policy without retaining the exposed MITM CA private material | No | ready to apply; phone validation pending |
| `notes/tailscale-shadowrocket-routing_v01_20260715-142300.md` | 2026-07-15 14:23 | 2026-07-15 14:57 | Live routing diagnosis | Confirm `bypass-tun`/`skip-proxy` excluded `100.64.0.0/10` before the `TAILSCALE` rules, while separating Safari `ws://` navigation from Bridge health | No while diagnosis remains active | root-cause-confirmed; client validation pending |
| `patches/bridge-setup_v01_20260714-075945.md` | 2026-07-14 07:59 | 2026-07-14 08:07 | Global service record | Record the requested `npx @ccpocket/bridge@latest setup`, self-disconnect recovery, verification, and rollback | No | active |
| `backups/20260714-075945_bridge-setup/` | 2026-07-14 07:59 | 2026-07-14 07:59 | Configuration backup | Exact pre-setup LaunchAgent plist | No while this setup remains active | active |
| `runs/20260714-075945_bridge-setup/` | 2026-07-14 07:59 | 2026-07-14 08:07 | Verification run | Setup transcript, hashes, plist snapshots, and service checks | Yes after the record is no longer needed | active |
