# Bridge 1.69.4-compat.7 会话同步恢复与部署记录

Status: deployed; physical-iPhone confirmation pending.

## 源码与修复

- 分支：`integration/mobile-session-sync-v2-20260730`
- 部署源码：`4c5f875ef031b5f89e418374e51ae1bb44b932e5`
- Mobile 修复：`84cedf15015409ea7d231767e0ff2824bbfa56fc`
- Bridge 修复：`9463fe3a572583dd14192ee91bc7e9634bfc044d`
- Bridge 版本：`1.69.4-compat.7`

本轮确认了两个独立问题：

1. durable 会话以本地 detached preview 打开，本来不会立即 attach provider，
   但 Codex/Claude 页面仍无条件显示“已连接，正在载入会话运行状态”，形成永久
   假加载。现在只有用户已经发送消息、真正等待 attach 时才显示该提示。
2. Mobile v2 任一 SQLite commit 失败都会取消并重订阅；每个成功 frame 又把退避
   计数清零，因此重复失败固定每两秒重试。现在首次非 thread 失败只清一次当前
   `(bridgeInstanceId, codexSourceId)` 的可重建缓存，保留 read watermark、草稿、
   凭据和设置；单 thread revision mismatch 只清该窗口；退避只在 priority
   checkpoint 或 sync complete 后归零。

Bridge 在 catalog/status state token 失效并发送 global reset 时，同时清除该
subscription 的 thread revision hints，使旧客户端得到一次有界热窗口重建；
read watermarks 保持不变，Bridge 复用已有 provider snapshot。

## 自动验证

- Mobile 全量：2,641 passed、4 expected skips、0 failures；
- Mobile 定向同步：11/11；
- Mobile durable preview/input：14/14；
- Flutter analyze：0 error、0 warning、52 个仓库既有 info；
- Bridge 定向：13/13；
- Bridge 全量串行：96 files、1,859/1,859 tests；
- Bridge 默认并行全量的既有 filesystem-watch 测试出现两种不同的时序失败；
  该文件隔离 8/8 通过，完整串行门禁通过，因此记录为资源竞争型测试抖动，
  没有伪称并行全量 clean；
- Bridge TypeScript build、native file-browser helper、生产依赖安装和
  `npm ls --omit=dev --all` 通过；
- `git diff --check` 通过。

## 候选与实际协议 smoke

隔离 `127.0.0.1:18765`：

- `/health` 和 `/version` 通过；
- legacy：320 catalog、320 status、最大帧 65,127 bytes；
- capable：320 catalog、320 status、最大帧 65,129 bytes；
- status reset 和 sync complete 均完成。

正式 `127.0.0.1:8765`：

- legacy/capable 均收到 catalog/status scoped reset；
- 320 catalog、320 status、102 timeline pages；
- capable 最大帧 65,139 bytes；
- ACK、priority checkpoint 和 sync complete 完成。

## Runtime 与正式切换

- 当前 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.7-4c5f875e`
- 回滚 runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.6-19ee1609`
- LaunchAgent：
  `/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist`
- 部署后 PID：`56059`
- 唯一 listener：`127.0.0.1:8765`
- `/health`：`ok`
- `/version`：`1.69.4-compat.7`

第一次切换脚本在错误 trap 中误用 zsh 只读变量 `status`，发生于旧 job 已
bootout、plist 已指向 compat.7 之后。服务短暂处于停止状态，但会话和手机数据
未修改；随后使用 bash 启动并完成全部健康与协议门禁。该事故没有被写成一次
无中断切换。

Runtime SHA-256：

- `dist/cli.js`：
  `e12c180058a8a6979df899daa8c09cd70c24046bd03d61509991d35893c07a17`
- `dist/websocket.js`：
  `b42f465f95afb5370b85e6afc52959f36de1d23fc2de4d08126fad48207cd80c`
- `dist/local-features/conversation-sync-v2.js`：
  `d50f56d6ae66c8c7aedaf352126c4e4f108abdd8124b0dcdfb5d302c5c76397e`

验证后删除 compat.5 runtime（约 257 MiB）；只保留 compat.7 当前版和
compat.6 直接回滚版。隔离 18765 smoke 生成的可重建
`prompt-history-v2-18765.json` 也已删除。没有修改 Mullvad、Tailscale、Cloud、
会话权威历史、真实手机缓存或 Shorebird channel。

## 设备门禁

部署验证时 `/health` 为 `clients=0`，因此只确认服务端和真实数据源可用，不把
物理手机重连、会话打开、视觉状态或后台行为写成已验收。build 206 可以直接从
Bridge global reset 修复受益；Mobile 的一次性缓存自愈和假加载 UI 修复需要
build 207。
