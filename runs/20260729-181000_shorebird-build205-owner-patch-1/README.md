# CC Pocket build 205 / owner Patch 1 发布记录

- 发布日期：2026-07-29
- 来源分支：`fix/mobile-connection-readiness-20260729`
- 功能提交：`6b701a3965277cf237abb3a644d9508cd39c279e`
- Mobile 版本：`1.109.3+205`
- Shorebird CLI：`1.6.114`
- Flutter：`3.44.7`（`309dd6573a9fe716410489284cd325a34b950375`）

## 精确 release 基线

- Shorebird release ID：`737381`
- 云端状态：iOS `active`
- Release 来源提交：`8c1d990768681b4ad29f9c7ae44bd0b2f255563a`
- 权威 AltStore/AltServer 输入包：
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.109.3-build205-Shorebird-release-8c1d9907-AltStore.ipa`
- IPA 大小：`25,920,877` bytes
- IPA SHA-256：
  `da0d0b16b5e332473383d28e37778b29cff391190e345a417422fed9524613f6`
- 云端 release 与 IPA 内 `App.framework/App` SHA-256：
  `3064b2f3b8fb6fcd1c56b9d645aaddec29cee2f50df719d0c8ac158ef5cc1a48`
- ZIP 完整性、版本 `1.109.3 (205)`、Bundle ID
  `com.k9i.ccpocket` 均已复核。

此前同版本名的
`CC-Pocket-1.109.3-build205-comprehensive-8c1d9907-AltStore.ipa`
来自 `shorebird release --dry-run`，其 `App.framework/App` SHA-256 为
`764925ec687e1c7b7930a500dd71d0deef26b876c9773fe5e1ac5e7ef55587f9`，
与真实云端 release 有大量字节差异，不能作为本 Patch 的安装基线。测试前必须
先安装本记录中的精确 release IPA，即使手机界面显示的版本号和构建号仍然相同。

## owner Patch 1

- Patch ID：`570773`
- Patch number：`1`
- Track/channel：`owner`
- iOS arm64 artifact ID：`1313465`
- Artifact 大小：`3,591,545` bytes
- Artifact SHA-256：
  `ed2ef92f9d2fc42aed9c90bc43f4511a93aae47eab09282bf63e8f2ba8afcb53`
- Rolled back：`false`
- `stable`：未晋级、未修改。

发布使用项目的严格脚本与 RSA 公私钥，不带
`--allow-native-diff` 或 `--allow-asset-diff`。Shorebird 的
“Verifying patch can be applied to release”通过后才上传，并成功晋级
`owner`。AOT 链接报告与 release 共享 `87.7%` 的 Dart 代码，低于预期但不构成
兼容校验失败；真机测试时应额外观察启动、会话目录进入速度和持续交互性能。

## 本次修复与后端边界

Patch 对应的源码修复会在 Mobile 收到过早或不完整的初始
`session_list` 后重建未完成的会话目录握手，并补充手机端 readiness 日志。
相关自动验证为 178 项通过；定向静态检查无问题。

本次功能提交没有修改 Bridge、Cloud Function、协议、iOS 原生代码、依赖锁或
资源。发布后仍运行 Bridge `1.69.4-compat.3`，因此没有重启或更新后端；这避免
把一个 Mobile 启动状态机修复扩大成无关的运行时切换。

## 真机测试顺序

1. 用 AltStore/AltServer 安装上述精确 Shorebird release IPA，覆盖手机上原有
   的 dry-run build 205。
2. 打开 CC Pocket，使用 `owner` 更新通道检查并下载 Patch 1。
3. 按 App 提示完整退出并重新打开。
4. 连接 Bridge，检查能否顺利进入会话目录和会话。
5. 若仍卡住，导出 Debug 日志；新日志可区分初始目录帧、当前连接代、
   recent-catalog 请求和 readiness 状态。

## 发布门禁

- 已完成：精确云端 release、精确基线 IPA、owner Patch 1、云端 JSON 复核。
- 未执行：`stable` 晋级、物理 iPhone 安装、Bridge 更新、Cloud Function 部署。
- 真机成功前，不应把这次发布写成 stable 或设备验收完成。
