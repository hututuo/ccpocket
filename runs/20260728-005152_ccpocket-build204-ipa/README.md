# CC Pocket 1.109.2 build 204 IPA

Status: built and audited; unsigned AltStore/AltServer candidate.

## Source

- Branch: `fix/mobile-comprehensive-v02-20260726`
- Mobile source commit: `576c90a8bd7fffad2b166d4ebf5f5eb8478d5e69`
- Startup compatibility fixes:
  - `dfc83aa7` — resend catalog bootstrap after an early `session_list`
  - `351d0444` — require recent-catalog authority from the current connection epoch
- Build-number commit: `576c90a8` (`1.109.2+204`)

## Focused regression

- Home/session-catalog bootstrap suite: 54 passed.
- BridgeService usage and same-target reconnect suite: 41 passed.
- Unknown approval-policy Plan-toggle regression: 2 passed.
- The source fix is event-order independent: both
  `session_list → connected` and `connected → session_list` trigger exactly one
  recent-catalog bootstrap for the authoritative generation.

## Build

- Shorebird CLI: `1.6.114`
- Flutter: `3.44.7` (`309dd6573a9fe716410489284cd325a34b950375`)
- Command class:
  `shorebird release ios --dry-run --no-codesign -- --no-tree-shake-icons`
- Xcode archive: 385.4 seconds.
- Result: `Runner.xcarchive` built; Shorebird reported `No issues detected`.
- The dry run did not upload a release or change any OTA channel.
- Codesigning was disabled because this Mac has no valid signing identity.
  The audited `Runner.app` was wrapped as `Payload/Runner.app` for
  AltStore/AltServer to sign during installation.
- Existing non-blocking warning: the project still uses Flutter's default
  launch-image placeholder.

## Artifact

- Path:
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.109.2-build204-comprehensive-576c90a8-AltStore.ipa`
- Size: `26,427,338` bytes.
- SHA-256:
  `279b659c4e494955e41d4087b0f6bc9e54fb1e106d028349e1fab93810799066`

## Package audit

- ZIP integrity passed; 287 safe relative entries.
- Exactly one top-level application: `Payload/Runner.app`.
- No `__MACOSX`, `.DS_Store`, absolute path or parent traversal entry.
- A fresh extraction matched the archived `Runner.app`.
- Bundle: `com.k9i.ccpocket`.
- Version/build: `1.109.2 (204)`.
- Minimum iOS: `15.0`.
- 35 Mach-O files: arm64 and iPhoneOS only.
- The top-level app is unsigned and has no `embedded.mobileprovision`, as
  expected for the AltStore/AltServer handoff.
- `UIBackgroundModes`: `fetch`, `location`, `remote-notification`.
- The packaged Firebase project remains `dummy-project`; this IPA therefore
  does not prove FCM/APNs remote delivery.

## Remaining device gates

- AltStore/AltServer must re-sign and install the IPA on the physical iPhone.
- The build-203 startup stall is fixed in source and automated regressions, but
  only build 204 can verify the real phone event order.
- Physical launch, Always Location, background keepalive, notification actions,
  APS entitlement after re-signing, Face ID, and real-device UI/performance
  remain unverified.
- No Bridge deployment, OTA publication, stable promotion or device install was
  performed by this build task.

## Cleanup

- After the build-204 artifact and record were verified, removed:
  - the superseded build-203 IPA;
  - this run's Flutter `build/` and `.dart_tool/`;
  - the exact Xcode `Runner-bofkvebdfnayizgbbeqxkrwpiycv` DerivedData;
  - the two build-204 staging/extraction directories.
- Pre-clean measurements total about 1.68 GiB of reproducible or superseded
  data.
- Retained exactly two delivery IPAs: build 204 plus the older build-199
  Shorebird rollback baseline.
- Free space after cleanup: about 18 GiB.
