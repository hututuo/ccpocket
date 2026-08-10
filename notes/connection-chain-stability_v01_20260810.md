# CC Pocket 连接与会话同步链路稳定性收束 v01

状态：源码实现、自动验证、Luna Max / Sol Max 独立复审及提交完成，等待独立发布门禁

基线：`c367874be08f0937ba03240715cc98a32a0b1c78`（build 228 源码）

## 用户现象

- 局域网路线可探测，进入应用时仍可能停在 `88%`。
- 同一台手机会反复断开、重连；重新连接后又重复加载目录和优先会话。
- 已经提交过的本地缓存会在新一轮刷新失败后失去“可用缓存”资格。

## 全链路结论

| 层 | 现场证据 | 结论 | 收束动作 |
|---|---|---|---|
| Bridge runtime | `/health`、`/readyz` 均为 200，shared daemon、Action Broker、writer lease 均 ready | Bridge 应用运行时不是本次 88% 的阻断点 | 保留现有 readiness 门禁 |
| LAN route | 生产代理日志出现 `no private IPv4`，随后出现 `EADDRNOTAVAIL`、`ECONNRESET`、`EPIPE`、`ETIMEDOUT` | 生产 helper 仍是旧版；单次 `en0` 空观测会关闭健康 listener 和 WebSocket | 部署仓库已验证的新 helper：暂时无地址时保留 listener；新地址连续确认后才 rebind |
| WebSocket authority | 每次连接均收到 `client_capabilities`、`list_sessions`，并进入 v2 subscribe | 认证和初始 session list 已通过；不能把故障归为“还没连上” | 保留 socket/session-list generation fence |
| conversation_sync_v2 | Bridge 日志反复出现 `subscribe → 1–3 ACK → unsubscribe`，没有 priority checkpoint | Mobile 在首个无法提交的优先时间线处主动退订 | 修复 scoped revision recovery；Bridge 增加有界生命周期摘要 |
| Mobile SQLite | patch 的 `baseRevision` 与已提交 hot window 不符时返回 `baseRevisionMatched=false` | 恢复代码只重启订阅，却继续广告同一旧 revision，形成确定性死循环 | 保留旧可读窗口，但下一次订阅只对出错 thread 省略 revision，强制 Bridge 发 snapshot；snapshot 原子提交后解除强制状态 |
| 缓存 readiness | `beginConversationSync` 每次把持久 `priority_ready` 清零 | 一次失败刷新会抹掉上一份完整缓存的可用标记 | 仅新 partition 默认 false；本次 socket readiness 由内存状态归零，持久 committed readiness 保留 |
| 手动/停滞恢复 | v2 的“重试目录”仍走 legacy `list_recent_sessions` 路径或只请求 project history | 看似重试，实际没有重启卡住的 v2 subscription | 首页和停滞 watchdog 改为只重启当前 v2 subscription，不重连 WebSocket、不清缓存 |
| 日志性能 | Bridge 为每个 `conversation_sync_ack` 同步写一行 stdout | 大会话会产生数百行无诊断价值日志，放大 IO 并淹没断线原因 | 抑制逐 ACK 日志，改为 subscribe、priority checkpoint、complete、unsubscribe 四类脱敏摘要 |

## 不变边界

- Provider/Codex 历史仍是权威数据，SQLite 仍是可重建副本。
- 不用缓存绕过本次 socket 的自动首页门禁；用户显式“使用缓存进入”仍只使用上一份完整提交。
- revision 冲突只重置一个 provider thread，不清空其他会话、目录、状态、未读或 read watermark。
- sequence gap 继续只重建流，不据此清空缓存。
- Mobile 与 Bridge 的协议字段不变；旧 Bridge、新 Bridge、旧 Mobile 的既有协商继续工作。
- LAN proxy 仍只暴露 Bridge 既有端口和鉴权模式；本次稳定性修复不扩大网络访问面。

## 验证与部署边界

源码验证需要覆盖：

1. stale base revision 保留旧窗口，并在一次 retry 后收到完整 snapshot；
2. 新同步开始不清除持久 committed priority cache；
3. v2 手动刷新不发重复 legacy catalog 请求；
4. Bridge ACK 洪泛不再写日志，生命周期摘要可定位未完成阶段；
5. LAN helper 短暂读不到 `en0` 时继续存活并保留 listener；
6. Bridge 与 Flutter 定向、全量、analyze 和 iOS simulator 构建通过。

生产启用是独立门禁：

- Mobile 修复需要新的 owner OTA 或 IPA；当前 build 228 不包含本轮修复。
- Bridge 日志修复需要构建并切换新 runtime。
- LAN 稳定性需要替换独立 helper 并只重启 `com.ccpocket.bridge-lan-proxy`；不应重启 Bridge 或 shared app-server。
- 物理 iPhone 需要验证局域网保持连接、首次同步越过 88%、后台/前台恢复和手动刷新。

## 本轮验证记录

- Mobile 定向回归：会话 v2 同步、目录缓存、手动刷新和首页首轮共
  `233/233` 通过；最终恢复/进度组 `192/192`，最后的依赖注入防御性门禁组
  `158/158` 通过。
- Mobile 全量回归：`3079` 项通过，`4` 项按既有环境条件跳过；最后两行
  防御性门禁在全量后加入，并已由上述 `158/158` 定向回归覆盖。
- `flutter analyze --no-pub`：`0 error / 0 warning`；报告 `53` 条仓库既有
  info，本轮没有新增 warning。
- Bridge 最终 conversation-sync 定向回归：`139/139` 通过；Bridge 全量：
  `118` 个文件、`2412/2412` 通过；TypeScript 与 native file-browser helper
  构建通过。
- LAN helper：语法检查及 `8/8` 单测通过。隔离端口 `18769` 的 `/readyz`、
  `/version` 和完整 WebSocket v2 同步通过，未修改生产配置。
- iOS Simulator Debug：较早完整构建 `108.1s`；最终源码快照增量 Xcode build
  `12.9s`，均成功生成 `Runner.app`。
- 真实只读 full-sync 探针：首轮样本 `155` 个事件、约 `6.52 MiB`、最大帧
  `65,233` 字节、`5.49s` 完成；同机 LAN proxy 暖运行样本 `158` 个事件、
  `1.34s` 完成。使用前一轮 state token 重连时 `0` 个 timeline page，约
  `21–27 KiB`、`0.92s` 完成，证明无变化重连不会重复发送历史窗口。

上述探针验证的是 Bridge/proxy wire 行为，不替代物理 iPhone 上的 SQLite 提交、
页面门禁、真实 Wi-Fi 切换和后台恢复验收。当前物理 iPhone 未对 Xcode 可用，因此本轮
没有声称真机问题已经消失。

独立复审结论：Luna Max 与 Sol Max 均为 `NO BLOCKER`，未发现 P0/P1/P2/P3
源码问题。仍有两个非阻断测试缺口：Bridge 的 ACK 日志抑制和未完成 socket 断线
warning 尚未逐分支直接断言；前后台、watchdog、手动刷新与 live gate 尚未在物理
iPhone 上做一次完整串联验收。这些不改变源码结论，也不得被表述为真机验收完成。
