# CC Pocket 1.109.2 build 203 IPA

Status: built and audited; unsigned AltStore/AltServer candidate.

## Source

- Branch: `fix/mobile-comprehensive-v02-20260726`
- Mobile source commit: `0ee7c417` (`1.109.2+203`)
- Bridge source/runtime version: `1.69.4-compat.2`
- Official base already included: `upstream/main@aa215a3b`

## Build

- Shorebird CLI: `1.6.114`
- Flutter: `3.44.7` (`309dd6573a9fe716410489284cd325a34b950375`)
- Command class: `shorebird release ios --dry-run --no-codesign`
- Xcode archive: 128.9 seconds
- Result: `Runner.xcarchive` built; Shorebird reported `No issues detected`.
- Dry-run did not upload a release or change `owner` / `stable`.
- Because codesigning was disabled, Shorebird intentionally did not export an IPA.
  The audited `Runner.app` was wrapped directly as `Payload/Runner.app` for
  AltStore/AltServer to sign during installation.

## Artifact

- Path:
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.109.2-build203-comprehensive-0ee7c417-AltStore.ipa`
- Size: `25,766,643` bytes
- SHA-256:
  `c40472f5492e491cdcd7f187a39b6d48a673810c2aaac67680ebc7c3afa28dcb`

## Audit

- ZIP integrity passed; 287 safe relative entries.
- Exactly one top-level app: `Payload/Runner.app`.
- No `__MACOSX`, `.DS_Store`, absolute path or parent traversal entry.
- Fresh extraction matched the archived `Runner.app`.
- Bundle: `com.k9i.ccpocket`.
- Version/build: `1.109.2 (203)`.
- Minimum iOS: `15.0`.
- 35 Mach-O files: arm64 only, iPhoneOS platform only.
- Top-level app is unsigned and has no `embedded.mobileprovision`, as expected
  for the AltStore/AltServer handoff.
- `UIBackgroundModes`: `fetch`, `location`, `remote-notification`.
- Shorebird app identity is present.
- The packaged Firebase project remains `dummy-project`; therefore this package
  does not prove FCM/APNs remote notification delivery. Local notifications and
  the connected-Bridge notification-only path remain separately testable.

## Remaining device gates

- AltStore/AltServer must sign and install the IPA on the physical iPhone.
- Physical launch, Always Location authorization, background keepalive,
  notification actions, APS entitlement after resigning, and real-device UI /
  performance remain unverified.
- Current live Bridge has no connected phone at the deployment check, and the
  Mac-local Tailscale IPv4 probe timed out; phone reconnection is not claimed.

## Build and cache cleanup

- Removed the superseded build-202 IPA after build 203 passed the complete
  archive audit.
- Retained exactly two delivery IPAs: build 203 plus the older build-199
  Shorebird baseline as a rollback source.
- Removed the oldest inactive Bridge runtime
  `1.69.0-compat.6-4e611c6b`; retained current compat.2 plus compat.1 rollback.
- Removed two Xcode-created `Clone 2 of iPhone 17 Pro Max` directories from
  `~/Library/Developer/XCTestDevices`; the user's normal iPhone 17 Pro Max
  Simulator remains.
- Ran `flutter clean` after packaging, removing the archive and active
  Flutter build caches.
- Exact old runtime, old IPA and XCTest clone removal freed
  `7,235,140,876` bytes; the measured Flutter build and `.dart_tool` cleanup
  removed about another 630 MiB of reproducible data.
