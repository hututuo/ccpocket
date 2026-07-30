# CC Pocket 1.110.1 build 208 Shorebird base

Status: cloud base published and unsigned AltStore input IPA audited; physical
iPhone installation and behavior acceptance remain pending.

## Source

- Integration branch: `integration/mobile-session-sync-v2-20260730`
- Release source commit:
  `89a5c5e85a0db6860a32dd8c95182dee803ec9af`
- Pre-release safety tag:
  `safety/mobile-session-sync-v2-build208-pre-20260730`
- Flutter: `3.44.7` (`309dd6573a9fe716410489284cd325a34b950375`)
- Shorebird CLI: `1.6.114`
- Shorebird app:
  `e58996aa-9bee-48b7-8ac9-10525380349b`

## Why build 208 was required

The installed build 207 was produced as an unsigned AltStore package, but it
was never uploaded as a Shorebird base release. Live Shorebird inspection on
2026-07-30 showed iOS releases `1.109.3+205`, `1.107.2+199`, and
`1.107.2+198`; no `1.110.1+207` release existed. Consequently build 207
cannot receive a real OTA patch.

The session-list stability repair is Dart-only, but a new base was required to
establish a valid OTA lineage. The Mobile version was advanced monotonically
from `1.110.1+207` to `1.110.1+208`.

## Cloud release

- Release: `1.110.1+208`
- Release ID: `739446`
- Platform: iOS
- Status after upload: `active`
- Patches immediately after release: none
- Existing `owner` and `stable` patches were not promoted, replaced, or
  modified.
- Embedded Shorebird public key matches the configured owner public key.
- Build command used the repository release gate with `--no-codesign` and
  Flutter `3.44.7`; this was a real upload, not `--dry-run`.

## Artifact

- Path:
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.110.1-build208-session-sync-v2-89a5c5e8-AltStore.ipa`
- Size: `25,741,221` bytes
- SHA-256:
  `1eee1473d81b8744b5f906106a4d341fa946950076933944ef2e472be4fcc2c7`

## Audit

- ZIP integrity passed; 279 safe relative entries.
- Exactly one app root: `Payload/Runner.app`.
- No absolute path, parent traversal, `__MACOSX`, or `.DS_Store` entry.
- Fresh extraction matched the stripped staging app byte-for-byte.
- Bundle ID: `com.k9i.ccpocket`.
- Version/build: `1.110.1 (208)`.
- Minimum iOS: `15.0`.
- 35 Mach-O files; all are arm64 and iPhoneOS.
- No Mach-O signature, `_CodeSignature`, or `embedded.mobileprovision`.
- `UIBackgroundModes`: `fetch`, `location`, `remote-notification`.
- Firebase project remains `dummy-project`; this package does not prove
  APNs/FCM remote notification delivery.
- The existing Flutter default launch-image warning remains non-blocking.

## Transfer and installation gate

Two CC Pocket transfer attempts returned
`No compatible live phone is connected`, so the Bridge did not offer the IPA
and phone-side saving is not claimed. The file is ready for a later transfer.
AltStore/AltServer must still re-sign and install the package before build 208
is active on the physical iPhone.

## Validation inherited from the repair source

- Mobile full suite: 2,647 passed, 4 expected environment skips, 0 failed.
- Bridge v2 targeted suite: 14 passed; TypeScript and native helper prebuild
  passed.
- Flutter analyze: 0 errors, 0 warnings, 52 existing info-level lints.
- `git diff --check`: passed.

The Bridge production runtime was not changed by this repair. Only a Bridge
protocol regression test was added, so no Bridge restart is required for build
208.

## Build and cache cleanup

- Removed the verified, rebuildable Mobile `build/`, iOS `Pods/`, and Flutter
  ephemeral directories: approximately `466,276,352` logical bytes.
- Kept the active worktree's `.dart_tool`, the small Bridge `dist`, and the
  audited build 208 IPA.
- Kept build 207 as the direct rollback IPA.
- Moved the superseded build 206 IPA to
  `/Users/huyiyang/.Trash/CC-Pocket-1.110.1-build206-session-sync-v2-065cddc0-AltStore.ipa`;
  it remains recoverable from Trash.
- No simulator or XCTest clone was created by this release.
