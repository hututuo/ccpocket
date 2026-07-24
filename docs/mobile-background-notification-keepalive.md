# Optional Background Local Notifications

## Product contract

This is an opt-in iOS extension for a self-signed CC Pocket build. While at
least one agent task is active, the user may allow CC Pocket to keep a
lightweight Bridge socket available in the background and turn selected Bridge
events into local iOS notifications.

The extension has four non-negotiable limits:

1. It requires an explicit user action and iOS **Always Location** permission.
2. `CLLocation` values are never read, stored, logged or transmitted.
3. Background delivery contains only compact notification envelopes. Stream
   deltas, history, file data, tool payloads and conversation rendering stay
   disabled.
4. Returning to the foreground restores interactive delivery first, then uses
   the existing history sequence to reconcile the missed increment.

This is not APNs or FCM. It can provide local notifications while this
location-backed execution lease remains active even when a free signing profile
does not preserve APS entitlement. iOS can still stop the app, and force-quitting
the app prevents background execution until the user opens it again.

## Lifecycle and ownership

1. In the foreground, the Bridge uses `interactive` delivery and the existing
   conversation runtime owns normal streaming.
2. During the foreground-to-background transition, Mobile may pre-arm the
   coarse native location host. This is done before full suspension because
   iOS does not reliably allow a newly suspended process to start location work.
3. Once the app reaches a background lifecycle state, Mobile sends
   `set_client_delivery_mode(mode: notifications_only)`. The Bridge acknowledges
   with `client_delivery_mode_state_v1`.
4. The Bridge discards pending stream batches for that socket and projects only
   selected approval, question, progress, completion and failure events into
   `background_notification_v1`. It also reports aggregate active-work state in
   `background_activity_state_v1`.
5. Mobile applies the same whitelist to raw JSON before normal message parsing,
   runtime storage, Mirror reconciliation or widget rendering. A system
   `BGAppRefresh` delivered while this mode owns the background transport
   completes without requesting session data.
6. On resume, Mobile requests `interactive` delivery before re-enabling resident
   watches or requesting any session list/history. The existing foreground
   reconciliation then fills the gap by sequence rather than replaying the
   background stream.

Feature ownership is deliberately narrow:

- `background-delivery-protocol.ts` and
  `background-notification-projector.ts` own the additive Bridge protocol and
  privacy-bounded projection.
- `BackgroundLocationKeepAlivePlugin.swift` owns the native execution primitive
  and resource-pressure shutdown.
- `background_location_keep_alive_host.dart` owns the capability-gated method
  channel.
- `background_notification_mode_controller.dart` owns permission, policy,
  delivery-mode and power state.
- `background_sync_coordinator.dart` owns only lifecycle ordering and the
  foreground incremental catch-up.

## Power and privacy bounds

- The base app defaults to reduced location accuracy. Native accuracy is
  `kCLLocationAccuracyThreeKilometers` with a 1 km distance filter, and the app
  requests no temporary fine-location access.
- The lease starts only when the feature is enabled, the Bridge is connected,
  a task is active, Always Location is granted, Low Power Mode is off and the
  thermal state is below serious.
- It stops when active work reaches zero, the user disables the feature, the app
  returns to the foreground, Low Power Mode begins, thermal state becomes
  serious/critical, authorization is lost, a location runtime error occurs, or
  the Bridge remains disconnected for two minutes.
- iOS' background-location indicator remains visible. The feature must never
  hide that system disclosure.
- Intermediate progress is opt-in and Bridge-rate-limited to one changed stage
  per session every 45 seconds.
- Privacy mode removes conversation labels, result text, question text, tool
  names, tool identifiers and provider-specific result metadata. Only the
  durable session/provider routing identity remains.
- File transfer, previews, history pages, Mirror pages and arbitrary command or
  tool input are never delivered in notification-only mode.

## Compatibility matrix

| Installed Mobile / Bridge | Behavior |
|---|---|
| Old Mobile / new Bridge | Unchanged. The client never advertises or requests notification-only delivery. |
| New Dart on an old base IPA / any Bridge | `backgroundLocationKeepAlive` is absent. The setting fails closed and asks for a new base IPA; existing permissions and foreground sync continue. |
| New base IPA and Dart / old Bridge | The Bridge capability is absent. Mobile retains the existing finite background continuation and foreground reconciliation. |
| New base IPA and Dart / new Bridge | Notification-only mode is available after explicit permission and setting opt-in. |
| New base IPA / rolled-back old Dart | The native plugin remains dormant because old Dart never calls its channel. |
| New Mobile / Bridge disconnect or mode timeout | The location pre-arm is stopped. Mobile falls back to the existing bounded background behavior and foreground reconciliation. |

All additions are capability-gated:

- Native: `backgroundLocationKeepAlive: 1`
- Permission host: API v3 adds `locationAlways`; Dart still accepts API v2 so
  old base IPAs retain their existing permission management.
- Bridge: `background_notification_delivery_v1`

No existing database schema or canonical conversation message is changed.

## Release boundary

`BackgroundLocationKeepAlivePlugin.swift`, `UIBackgroundModes/location`,
location usage descriptions, Xcode registration and native capability metadata
require a newly built and signed base IPA. They cannot be introduced through a
Shorebird Dart patch.

After that base is installed, Dart policy/UI refinements may be published to
the `owner` track. The Bridge protocol may be deployed independently because
old clients ignore it. Source integration alone does not install the IPA,
replace the live Bridge, publish an owner patch or promote anything to
`stable`.

## Verification gates

Automated checks cover:

- strict capability and message parsing;
- Bridge-side stream suppression and privacy projection;
- Mobile raw-frame suppression before normal routing;
- pre-arm cancellation when the task ends before background entry;
- Low Power Mode and thermal fail-closed behavior;
- no history or Mirror activity during notification-only background delivery;
- interactive restoration before foreground history reconciliation;
- old Bridge and old base-IPA fallback.

The iOS Simulator can verify compilation, registration and deterministic state
logic only. A physical iPhone must still verify:

1. the two-step When In Use to Always permission flow;
2. the visible background-location indicator;
3. local approval/progress/completion notifications while the screen is locked;
4. no visible chat progression until the app is reopened;
5. incremental catch-up after reopening;
6. shutdown in Low Power Mode, after task completion and after a prolonged
   disconnect;
7. battery and thermal behavior over a representative long task;
8. behavior after AltStore re-signing and after a force-quit.
