# CC Pocket build 205 / Bridge 1.69.4-compat.3 交付记录

- 来源分支：`fix/mobile-comprehensive-source-closure-20260728`
- 来源提交：`8c1d990768681b4ad29f9c7ae44bd0b2f255563a`
- Mobile：`1.109.3+205`
- Bridge：`1.69.4-compat.3`
- 生成日期：2026-07-28

## IPA

- 权威交付物：
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.109.3-build205-comprehensive-8c1d9907-AltStore.ipa`
- 大小：`26,487,773` bytes
- SHA-256：
  `94db9907128f21338165aee1cf15626e588813528d4bbf583e18e5cbc6b50ceb`
- Bundle ID：`com.k9i.ccpocket`
- 最低 iOS：15
- 结构检查：287 个安全 ZIP 条目、唯一 `Payload/Runner.app`。
- 二进制检查：34 个 Mach-O 均为 arm64，不含模拟器架构。
- 原生能力标记已确认：有限后台续租、Always Location keep-alive、
  通知审批动作、permission host 和文件修改生物识别授权。
- 这是供 AltStore/AltServer 重签的无签名输入包，不含
  `embedded.mobileprovision`；本轮没有安装物理 iPhone。

本包仍使用仓库的 dummy Firebase 配置。它可以验证本地/Bridge 通知路径和原生
宿主接线，但不能据此宣称 APNs/FCM 远程推送可用。

## 构建与验证

- Shorebird `1.6.114` dry-run、`--no-codesign` 构建成功；未上传 release，
  未修改 owner/stable OTA channel。
- Xcode archive 完成；打包后的 IPA 经全新解压复核，版本、构建号、Bundle ID、
  架构和原生标记一致。
- 当前精确源码此前已完成：
  - Flutter 全量测试：2576 通过，4 个环境相关 SSH smoke skip。
  - iOS Simulator 构建通过。
  - RunnerTests：27/27 通过。
- 本轮 Bridge 全量测试：95/95 files、1836/1836 tests 通过；生产构建和原生
  file-browser helper 构建通过。
- Cloud Functions 使用 Node 22 完成 typecheck、24/24 tests 和 build。

## Bridge 更新

- 更新前 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.2-52579b6b`
- 当前 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.3-8c1d9907`
- 当前 LaunchAgent：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- `dist/cli.js` SHA-256：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js` SHA-256：
  `b72c60bee280881bd3a2bf1c3b6e836795558733778606dd0b9af07d694d4455`

隔离端口 18765 的候选 smoke 先通过。实际切换时发现 Tailscale TCP Serve 已拥有
本机 Tailnet 地址的 8765 监听，并转发到 `127.0.0.1:8765`。旧配置仍让 Bridge
绑定 `0.0.0.0:8765`，重启后会与 Tailscale 发生 `EADDRINUSE`。因此当前部署把
`BRIDGE_HOST` 收窄为 `127.0.0.1`，保留原端口、公开 URL、允许目录、文件传输和
会话数据配置。Tailscale 状态已确认：

```text
TCP 8765 -> 127.0.0.1:8765
```

激活后的本机 `/health` 为 `status=ok`，`/version` 为
`1.69.4-compat.3`，LaunchAgent 只有一个 PID 和一个 loopback 8765 监听者。
验证时手机客户端不在线，`clients=0`、`sessions=0`；Mac 对自身 Tailnet IP 的
hairpin 探针超时，因此手机从 Tailnet 重连仍是安装后的独立验收项。

## Cloud Function 边界

本轮没有部署 Cloud Function。临时授权的 Firebase CLI 账号列不到任何项目，
也无权访问源码中引用的旧项目名；没有在未经授权的情况下新建 Firebase 项目。
临时 Firebase CLI 登录已注销，Cloud 线上状态保持不变。

完整 FCM/APNs 通知仍需要：

1. 提供有权限的真实 Firebase 项目；
2. 在 App 中换入真实 `GoogleService-Info.plist`；
3. 部署对应 Cloud Function；
4. 确认 AltStore 最终签名保留 APS entitlement；
5. 在物理 iPhone 上完成推送和通知动作验收。

## 产物收束

- 保留 IPA：build 205 当前包、build 204 回滚包。
- 删除 IPA：已被替代的 build 199。
- 保留 Bridge runtime：compat.3 当前版、compat.2 回滚版。
- 删除 Bridge runtime：已被替代的 compat.1。
- 删除本轮 IPA staging/extract、临时 Firebase CLI、Bridge staging runtime、
  Flutter/Xcode/Functions 可重建缓存和两份 CC Pocket DerivedData。
- 可用空间由约 30 GiB 回升到约 38 GiB。

本轮没有合并稳定分支、push、发布 OTA、安装物理设备或修改会话数据。
