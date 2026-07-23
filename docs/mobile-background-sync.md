# Mobile Background Conversation Sync

## Scope

CC Pocket extends an already-running iOS conversation in two bounded ways:

1. When the app leaves the foreground during an active turn, a finite
   `UIBackgroundTask` keeps the existing Flutter runtime and WebSocket alive.
   Live Bridge events continue through the normal stream, and one bounded
   delta reconciliation repairs any gap.
2. The app may schedule `BGAppRefresh` for a later bounded reconciliation.
   Delivery time is controlled by iOS. The task handles only cached
   conversations and never starts an unbounded full-history transfer.

This feature does **not** use audio, location, VoIP, or any other misleading
background mode. It does not promise a permanently running process. If iOS
reclaims the process, the user force-quits the app, or no ready Flutter runtime
is available before the task deadline, the operation fails closed and the next
foreground resume performs the authoritative catch-up.

Notifications are outside this module.

## Ownership boundaries

- `BackgroundSyncHostPlugin.swift` owns the two native execution leases and
  exact-once iOS task completion.
- `background_sync_host.dart` owns the narrow, capability-gated method channel.
- `background_sync_coordinator.dart` owns lifecycle generations, cancellation,
  bounded session/history reconciliation, and foreground catch-up.
- `BridgeService` remains the canonical live session transport. The added
  reconciliation generation is internal to Mobile and adds no wire message.
- `ConversationMirrorService` remains a rebuildable cache. Background work may
  reconcile an existing resident watch, but it cannot recreate a missing watch
  or start a large first snapshot.

The native capability names are:

- `backgroundContinuation`
- `backgroundRefreshWarmRuntime`

The second name is deliberately narrower than `backgroundAppRefresh`: a future
cold/headless Flutter engine must use a new capability instead of silently
changing this contract.

## Compatibility matrix

| Installed IPA / Dart / Bridge | Behavior |
|---|---|
| Old IPA / old Dart / any Bridge | Unchanged. |
| Old IPA / new Dart / any Bridge | Native capabilities are absent, so native background execution is disabled. Foreground resume catch-up still works. |
| New IPA / old Dart / any Bridge | The native host stays dormant because old Dart never performs the readiness handshake. A task scheduled before an OTA rollback may fail once, but native code does not reschedule it indefinitely. |
| New IPA / new Dart / old Bridge | Background history uses delta-only requests. If the Bridge rejects `get_history_delta`, Mobile does not fall back to a potentially unbounded full history until foreground resume. Optional mirror requests fail closed. |
| New IPA / new Dart / current Bridge | Finite live continuation, bounded cached delta reconciliation, resident mirror reconciliation, and opportunistic refresh are enabled. |
| Any old Mobile / current Bridge | Unchanged because no Bridge wire or persistent schema was added. |

Capability fields are additive. Older Bridges ignore the new
`client_capabilities.mobileRuntime.nativeCapabilities` entries.

## Resource bounds

- Active-turn continuation tracking window: approximately 22 seconds.
- App-refresh execution budget: 25 seconds at the native boundary.
- Session list and history waits are independently bounded and cancellable.
- Foreground mirror reconciliation: at most 8 resident conversations, 12
  seconds.
- Background mirror reconciliation: at most 2 resident conversations, 8
  seconds, with missing-watch restoration disabled.
- Background history is requested only for conversations with an existing
  cached sequence.
- Expiration, lifecycle replacement, engine replacement, and disposal cancel
  their pending listeners and ignore late frames.

## Release boundary

The Swift plugin, Xcode project, `Info.plist`, and native capability snapshot
require a new base IPA. They cannot be delivered by Shorebird alone. After that
base IPA is installed, Dart-only policy and reconciliation tuning can be
delivered as an `owner` OTA patch.

This source change does not authorize publishing, promoting to `stable`,
installing on a physical iPhone, replacing the live Bridge, or enabling push
notifications.

## Verification gates

Automated gates cover:

- old-IPA fallback and old-Bridge delta-only behavior;
- startup readiness, duplicate task delivery, expiration, and engine
  replacement;
- lifecycle generation fencing across rapid background/foreground changes;
- continuation cancellation before foreground watch restoration;
- bounded mirror cancellation and rejection of late frames;
- native capability parsing and fail-closed missing capabilities.

iOS Simulator verifies compilation, registration, and deterministic controller
logic. A physical iPhone is still required to verify the system-selected
`BGAppRefresh` schedule, actual suspension timing, force-quit behavior, network
transitions, AltStore re-signing, and battery impact.
