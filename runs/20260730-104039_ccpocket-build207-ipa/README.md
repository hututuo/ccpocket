# CC Pocket 1.110.1 build 207 IPA

Status: built and audited; unsigned AltStore/AltServer input package.

## Source

- Branch: `integration/mobile-session-sync-v2-20260730`
- Source commit:
  `4c5f875ef031b5f89e418374e51ae1bb44b932e5`
- Bridge runtime: `1.69.4-compat.7`
- Flutter: `3.44.7`
- Shorebird CLI: `1.6.114`

## Build and tests

- Flutter full test: 2,641 passed、4 expected skips；
- Flutter analyze: 0 error、0 warning、52 existing info；
- iOS Simulator Debug: Xcode 253.8s，built `Runner.app`；
- RunnerTests: 27/27 passed；
- iPhoneOS Release `--no-codesign`: Xcode 160.2s，
  `Runner.app` 66.2 MB；
- `shorebird release ios --dry-run --no-codesign`:
  archive 205.2s、315.7 MB，`No issues detected`；
- dry-run did not upload a release or change `owner` / `stable`.

Shorebird reported the repository's existing default Launch Image placeholder.
The build also retains three plugin warnings about future Swift Package Manager
support. Neither warning changed this IPA's version, native capability or
archive result.

## Artifact

- Path:
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.110.1-build207-session-sync-v2-4c5f875e-AltStore.ipa`
- Size: `26,236,402` bytes
- SHA-256:
  `a5d57b79a62c2563e80d6c87c41604262934589b2f2e0b7f63222a84aa1e590f`

## Audit

- ZIP integrity passed；279 个安全相对路径条目；
- 唯一 app root：`Payload/Runner.app`；
- fresh extraction 与 staging app byte-for-byte 一致；
- Bundle ID：`com.k9i.ccpocket`；
- version/build：`1.110.1 (207)`；
- minimum iOS：`15.0`；
- 34 个 Mach-O 全部为 arm64 / iPhoneOS，无 x86_64 或 simulator；
- 顶层和嵌套 framework 均已移除签名；
- 无 `_CodeSignature`、无 `embedded.mobileprovision`；
- `UIBackgroundModes`：fetch、location、remote-notification；
- Face ID、Always Location、background sync/location、notification actions、
  MobileHost、Quick Look、file mutation auth 和 file transfer 原生标记存在。

仓库仍使用 `dummy-project` Firebase plist。该包可用于 AltStore 重签以及
Bridge 本地通知/原生宿主测试，但不能证明 APNs/FCM 远程推送已可用。

## Remaining device gates

- AltStore/AltServer 重签与物理安装；
- 真机启动、会话目录和会话打开；
- Always Location、后台 keepalive、通知审批动作；
- AltStore 重签后 APS entitlement；
- 真机性能、功耗和视觉验收。

## Build and cache cleanup

保留：

- build 207 当前 AltStore 输入包；
- build 206 直接回滚包；
- compat.7 当前 Bridge runtime 和 compat.6 回滚 runtime；
- 最新一次通过 RunnerTests 的一台 XCTest clone；
- 当前集成 worktree 的 Node 依赖。

删除：

- 被两版取代的 build 205 IPA；
- compat.5 Bridge runtime；
- 上一台 XCTest clone；
- IPA staging 和 fresh extraction；
- Mobile `build/`、`.dart_tool`、Pods 和 Flutter ephemeral；
- 本轮 Runner DerivedData；
- 18765 隔离 smoke 的可重建 PromptHistory 文件。

本轮最终缓存收束使 APFS 可用空间从约 69 GiB 回升到约 76 GiB；此前同轮删除
compat.5 和旧 XCTest clone 还分别收回约 257 MiB 和 3.9 GiB。源码、锁文件、
唯一部署记录、用户会话和真实手机数据均未删除。
