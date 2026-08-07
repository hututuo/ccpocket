# CC Pocket LAN and 79% readiness recovery

Status: source-verified; LAN production repaired; Bridge redeploy pending;
physical-phone acceptance pending.

## Incident evidence

Two independent failures were present.

1. The Mac's current Wi-Fi address is `192.168.124.219`, but
   `com.ccpocket.bridge-lan-proxy` still bound `192.168.124.67`. Launchd had
   attempted the job 17,722 times; its 11 MB stderr repeated
   `EADDRNOTAVAIL`. Bridge itself correctly remained on loopback because
   Tailscale TCP Serve owns the Tailnet address on port 8765.
2. Mobile's 79% is the explicit `preparingCodexRuntime` stage. Live Bridge
   `/health` showed `applicationReady=false` and
   `action_broker_writer_unavailable`. The owner file still named the live
   Bridge PID and exact daemon socket, but its heartbeat had stopped. The lease
   cleared its in-memory owner on an asynchronous heartbeat failure without
   notifying `CodexActionBrokerRuntime`, so no retry timer was armed.

## Implemented corrections

- System-tools commit `c4aae8fa8c08e06898181aafe33919478a6a9077`
  replaces the fixed LAN host with private IPv4 discovery and a five-second
  rebind monitor. It preserves WebSocket credential verification and upstream
  loopback routing.
- Bridge commit `71635557b44b57f9d9fcd3536e77c8efd6799a2d`
  emits typed `owner_mismatch` or `heartbeat_failed` events. Runtime responds by
  dropping the stale authority generation, notifying observers and scheduling
  its existing source/daemon-fenced lease acquisition.

## Live recovery

The stale production Bridge runtime was restarted without changing
`BRIDGE_CLI_ENTRY`. Bridge PID changed from 56290 to 27737; shared app-server
PID 16568 and its socket stayed unchanged. `/readyz` returned ready with writer
lease authority `cab:35:35`. The dynamic proxy runs as PID 27484 on
`192.168.124.219:8765`, while Bridge remains on `127.0.0.1:8765`.

## Verification

- Dynamic proxy unit tests: 3/3 passed.
- Candidate and installed proxy: HTTP health 200, missing-key WebSocket 401,
  correct-key WebSocket opened; installed stderr stayed empty.
- Bridge targeted build and tests: 3 files / 28 tests passed, including a real
  timer-driven lease-loss/reacquisition regression.
- TypeScript build and native file-browser helper build passed.
- `git diff --check` passed before the behavior commit.

The production Bridge still runs the previous code after the immediate
same-runtime restart. A versioned Bridge candidate, full regression and normal
production switch are required for permanent recovery. No Mobile, IPA, OTA,
Cloud, Tailscale/Mullvad switch, Desktop environment or session data changed.
