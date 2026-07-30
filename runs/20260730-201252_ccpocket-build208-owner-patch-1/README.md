# CC Pocket build 208 / owner Patch 1 发布记录

## 发布结果

- 发布日期：2026-07-30
- 来源分支：`integration/mobile-session-sync-v2-20260730`
- 功能提交：`146c6f73010fcfd483aa2467ba4cb5e074633f9a`
- Base release：`1.110.1+208`
- Release ID：`739446`
- Release 来源提交：`89a5c5e85a0db6860a32dd8c95182dee803ec9af`
- Flutter：`3.44.7`
- Patch ID：`572749`
- Patch number：`1`
- Channel/track：`owner`
- Rolled back：`false`
- iOS arm64 artifact ID：`1317807`
- Artifact 大小：`3,891,451` bytes
- Artifact SHA-256：
  `f505d8a4dd754be6dbb563447391698dcd8209c9d99c71511623b6a8f725eaa6`
- `stable`：未晋级、未修改。

Patch 使用 CC Pocket 的 RSA 公私钥签名。云端在上传前完成
`Verifying patch can be applied to release`，没有使用
`--allow-native-diffs` 或 `--allow-asset-diffs`。

本机没有 Apple 开发证书，因此最终构建使用 Shorebird/Flutter 官方支持的
`--no-codesign`。这只跳过临时 IPA 的 Apple provisioning，不会跳过 RSA
Patch 签名、release 适配校验、原生差异门禁或资源差异门禁。

## 本次内容

- 把 Mobile 启动进度拆成 17 个真实事件阶段，不再只靠四五个百分比检查点。
- 圆形指示器保持持续旋转，确定性百分比和线性进度单独显示。
- 手机诊断日志记录连接 epoch、目录 frame/envelope/model/authority、
  identity、SQLite commit、v2 page、checkpoint 和失败类别。
- 日志不记录消息正文、标题、路径、host、token、API key 或 raw payload。
- Prompt History 延后到首页 ready 后执行，按 Bridge/source 身份去重，
  优先复用主 socket，并在 revision 未变化时跳过完整快照。
- 旧 Bridge 的 Prompt History 格式错误会快速失败；可选 requestId 和
  legacy timeout lane 防止迟到结果污染后续操作。
- Bridge 的 timeline 页面增加可选 phase/index/count；旧 Mobile 会忽略
  新字段。

## 验证

- Bridge 全量：`96` 个文件、`1888` 项通过。
- Bridge 定向协议：`459` 项通过。
- Mobile 全量：`2666` 项通过、`4` 个既有环境 skip、`0` 失败。
- 独立复审相关回归：`102` 项通过，结论 Approve，无 P1/P2。
- Flutter analyze：`0 error / 0 warning`；`52` 个仓库既有 info。
- targeted analyze：`No issues found`。
- `git diff --check`：通过。
- Base 与 Patch 源码的 iOS、Android、plugin、asset、entitlement、
  `pubspec.lock` 差异门禁：通过。

## 发布过程中的非产品失败

- 首次 xcarchive 下载连接在 `44%` 后约 50 分钟无字节增长，安全终止后重试；
  第二条连接数秒内完成下载，说明前一次是失活网络连接。
- 第二次尝试完成下载，但默认 Apple codesign 因本机无开发账号/描述文件失败；
  云端没有创建 Patch。
- 最终按官方 `--no-codesign` 路径完成 archive、AOT link、严格差异校验、
  RSA 签名、上传并晋级 owner。

失败尝试没有产生额外 Patch，也没有修改 owner/stable 之外的通道。

## 物理 iPhone 验收

1. 在 CC Pocket 的软件更新中选择 `owner`。
2. 检查并下载 Patch 1。
3. 完全退出 App 后重新打开。
4. 观察启动页是否显示更细的实时阶段，圆形指示器是否持续旋转。
5. 若仍失败，导出 Debug 日志；本版可以精确区分目录 frame 未到、解码失败、
   model 校验失败、authority 未接受、身份未绑定或 SQLite/v2 提交失败。

发布成功不等于物理设备已经验收。用户确认前不得把 Patch 1 晋级
`stable`。
