I'll start by exploring the repository structure to understand the codebase layout.
Let me read the core files across the chain.
以下为端到端只读审查结果。仓库未做任何修改。

---

## A. 端到端一致性（Bridge → CF → APNs/FCM → Mobile → 本地通知 → 长按 action → 回传复核）

**[A-1] [P0]** `apps/mobile/ios/Runner/NotificationActionHostPlugin.swift:52`
iOS 原生用默认 `ISO8601DateFormatter()` 解析 `occurredAt`，无法解析带小数秒的时间戳 → 长按 Allow/Reject 全链路（本地通知 + FCM 远程通知）在真机上全部静默失效。
- 触发场景：任何一次审批通知的长按操作。
- 证据：
  - 解析门禁 `ISO8601DateFormatter().date(from: occurredAt) != nil`（默认 `formatOptions = .withInternetDateTime`，**不含** `.withFractionalSeconds`）。
  - 生产端产出的字符串一定带小数秒：Dart 侧 `apps/mobile/lib/services/notification_service.dart:31` `(occurredAt ?? DateTime.now().toUtc()).toIso8601String()` → `2026-07-26T01:02:03.456Z`；Bridge 侧 `packages/bridge/src/websocket.ts:11099` `new Date().toISOString()` 同样带 `.mmm`。
  - 单测之所以绿：`apps/mobile/ios/RunnerTests/RunnerTests.swift:322` 用的是 `"2026-07-25T01:02:03Z"`（无小数秒），与生产格式不一致。
  - 解析失败 → `capture()` 返回 false → `AppDelegate.swift:73` 走 `super`，而 flutter_local_notifications 的 Dart 回调路径又被 `main.dart` 的 `_handleNotificationAction` 以 `occurredAt == null` 二次丢弃。
- 建议：Swift 侧改用带 `.withFractionalSeconds` 的 formatter 并对两种格式都做回退解析；单测补带毫秒/微秒的用例。

**[A-2] [P1]** `packages/bridge/src/websocket.ts:1251-1253` + `10969-10973`，`functions/src/index.ts:394-398`
Bridge 的 `tokenLocales / tokenPrivacyMode / tokenEnabledEventTypes` 是纯内存 `Map`，无持久化；而 FCM token 持久化在 Firestore。Bridge 重启（launchd 拉起、崩溃恢复）后本地 locale 表清空，`getRegisteredLocales()` 回退为 `["en"]`，CF 端 `if (tokenLocale !== body.locale) return false` 直接把所有 `zh/ja/ko` token 过滤掉 → **中文/日文/韩文用户在 Bridge 重启后彻底收不到任何推送**，且无任何错误可见。
- 证据：`private tokenLocales = new Map<string, PushLocale>();`（仅构造时初始化）；`return locales.size > 0 ? [...locales] : ["en"];`。
- 客户端只在 `connectionStatus == connected` 或设置变更时重新 register（`settings_cubit.dart:110-116`），若 App 已在后台且 socket 未重连，缺口会长期存在。
- 建议：locale/偏好以 token 为键持久化到 Bridge 本地存储，或由 CF 在 `notify` 时按 token 自身 locale 分组投递（把 fan-out 从 Bridge 移到 CF），彻底去掉 Bridge 内存态依赖。

**[A-3] [P2]** `functions/src/index.ts:396`
`if (tokenLocale == null) return body.locale === "en";` —— 旧客户端（无 locale 字段）只在本次 notify 的 locale 恰好是 `"en"` 时才收到。若该 Bridge 上注册的 token 集合中不含任何 `en` locale（例如只有一台中文手机），`getRegisteredLocales()` 永远不会产出 `"en"`，legacy token **永久静默**。
- 建议：始终额外发一份 `en` 兜底，或在 CF 内部按 token locale 分桶而不是由调用方枚举 locale。

**[A-4] [P2]** `packages/bridge/src/websocket.ts:11171-11181` vs `packages/bridge/src/background-notification-projector.ts:233-241`
两套通知构造逻辑（FCM 路径 / WS 背景投影路径）字段不对齐：FCM 路径的 `result` 事件**无隐私门禁**地写入 `subtype`、`stopReason`。
```ts
// websocket.ts:11171
const data = { sessionId, provider, subtype: msg.subtype, occurredAt: ... };
if (msg.stopReason) data.stopReason = msg.stopReason;   // 无 if (!privacy)
```
```ts
// background-notification-projector.ts:237
if (!privacy) { data.subtype = msg.subtype; if (msg.stopReason) ... }
```
- 建议：把 FCM 路径重构为复用 `projectBackgroundNotification`，消除第二实现。

**[A-5] [P2]** `packages/bridge/src/background-notification-projector.ts:120,140-143,157-161`
`ExitPlanMode` 被归入 `approval_required` 且 `data.permissionId` 被填充 → mobile 端 `background_notification_mode_controller.dart:121-126` 会给它挂上 `ccpocket_approval_v1` category → 用户可从通知直接"Allow"批准计划。而 App 内 UI 的 ExitPlanMode 批准通常伴随权限模式选择，通知按钮走的是裸 `ClientMessage.approveLiveOnly()`（`notification_approval_coordinator.dart:234`），语义降级。
- 建议：ExitPlanMode 走独立 eventType（如 `plan_ready`），不下发 approval category。

**[A-6] [P2]** `apps/mobile/lib/services/notification_service.dart:316-322`
Android 的 `AndroidNotificationDetails` 未声明任何 `actions`，`notificationApprovalActions` capability 仅在 iOS 的 `MobileHostSnapshotPlugin.swift:39` 声明。产品要求的"通知长按 Allow/Reject"在 Android 上完全不存在，且没有任何降级提示。
- 建议：Android 侧补 `AndroidNotificationAction` + `MainActivity` 侧接收器，或在设置页明确标注该能力仅 iOS。

**[A-7] [P3]** `packages/bridge/src/websocket.ts:11068-11151`
`permission_request` / `result` 的 FCM 分支不检查 `hasExplicitPushSubscriber`（只有 progress 检查了），过滤完全交给 CF。结果：即使没有任何 token 订阅该事件，Bridge 仍按 locale 数量发出 N 次 `notify` 请求，白白消耗 CF 速率限额。

**[A-8] [P3]** `packages/bridge/src/push-relay.ts:81-91` + `functions/src/index.ts:93`
locale fan-out 使一次业务事件放大为 N 次 `notify` HTTP 调用，而 `RATE_LIMIT_NOTIFY_MAX = 30 / 60s` 是 bridge 全局的。多语言 + 多会话并发时会提前触发 429，静默丢通知（Bridge 只 `console.warn`）。

**能力协商核对结果（正常）**：`apps/mobile/lib/models/messages.dart:4884-4887` 通告的三个消息类型与 `packages/bridge/src/websocket.ts:3832-3835` 的 `supportsBackgroundDelivery` 门禁一致；不支持时返回 `background_delivery_client_unsupported`，客户端在 `bridge_service.dart:2440` 有对应识别。此段无缺口。

---

## B. 隐私与功耗边界是否被代码强制

**[B-1] [P1]** `packages/bridge/src/websocket.ts:10028`（`trackSessionMessage` → `maybeSendPushNotification`）与 `10064`（notifications_only 投影）是**两条互不感知的并行链路**。当客户端处于 Always-Location 的 `notifications_only` 模式时，同一事件会同时产生：
1. WS `background_notification_v1` → 本地通知；
2. FCM 推送 → 系统通知。

且两条路径的通知 ID 算法不同，无法折叠：
- `apps/mobile/lib/features/background_sync/background_notification_mode_controller.dart:116` `Object.hash(sessionId, provider, eventType).abs()`
- `apps/mobile/lib/main.dart:862` 自定义 31 进制哈希

→ 用户看到重复通知。
- 建议：Bridge 侧在存在 `notifications_only` 客户端时抑制对应 token 的 FCM 推送（或反之），并统一 ID 算法。

**[B-2] [P2]** `apps/mobile/lib/features/background_sync/background_notification_mode_controller.dart:560-567`
断线时把 `_privacyMode = true` 作为 fail-private，但**重连后从不恢复**——只有用户手动改设置触发 `updatePolicy()`（`main.dart:951`）才会复位。一次网络抖动后，用户的通知会永久降级为隐私文案。
```dart
if (state == BridgeConnectionState.disconnected) {
  _privacyMode = true;   // 无对应的 connected 分支恢复
```
- 建议：在 `BridgeConnectionState.connected` 分支中从 `SettingsCubit` 重新拉取真实 privacy 值后再 `_refreshBackgroundDeliveryPolicy()`。

**[B-3] [P2]** `packages/bridge/src/websocket.ts:10976-10981`
`isPrivacyMode()` 是**全 bridge OR**：任一注册 token 开启隐私，所有设备的推送都降级为隐私文案。叠加 [C-2]（失效 token 永不清理），一台已卸载的隐私设备会永久污染全局策略。

**notificationsOnly gate 的正面结论**：`prepareServerMessageForClient`（`websocket.ts:11285-11299`）对 `notifications_only` 客户端做白名单过滤，且 **`send()`（11595-11613）与 `broadcast()`（11232）都经过该函数**，单播响应（`get_history`、mirror、file transfer 回包）同样被拦截；客户端侧 `bridge_service.dart:2424-2440` 还有第二道 `_shouldSuppressBackgroundWireMessage`。Mirror 侧 `background_sync_coordinator.dart:512-517` 在 `ownsBackgroundTransport` 时直接 return。**未发现绕过该 gate 的下行路径。**

**[B-4] [P2]** `apps/mobile/lib/features/background_sync/background_sync_coordinator.dart:545-571`
delta-only 的 deadline 传播本身正确（`_boundedTimeout` / `_boundedMirrorBudget` 都扣减 deadline），但 `_synchronize` 把任务串到全局 `_syncTail` 队列尾部。若 `enteringBackground` 的同步仍在跑，BGAppRefresh 的 25s 预算会被前序任务吃光，`_isCancelled` 在轮到自己时直接返回 false → 任务空转失败。
- 建议：BGAppRefresh 触发时抢占（cancel）前序 lifecycle 同步，而非排队。

---

## C. 安全

**[C-1] [Security: High]** `functions/src/index.ts:308-350`
`handleRegister` 对 token 只做格式校验（`isValidFcmToken`），**不验证 token 归属**。任何人都能用 Firebase 匿名登录拿到自己的 UID，把**受害者的 FCM token**（token 并非机密：出现在 Bridge 日志、Bridge 内存、Firestore、客户端日志）注册到自己的 `bridges/{ownUid}/tokens/` 下，随后发送任意 `title`/`body`，甚至构造 `eventType=approval_required` + 合法 `permissionId/occurredAt` 让 APNs 挂上审批 category。
- 影响：推送伪造 / 钓鱼（诱导长按 Allow）、骚扰、伪造"任务失败"。
- 缓解现状：最终审批仍受 `NotificationApprovalCoordinator._matchingSession`（`notification_approval_coordinator.dart:262-276`）的 Bridge 权威 pending 复核保护，无法真正批准；但 UI 欺骗与骚扰成立。
- 建议：register 时要求携带由 Bridge 与 App 之间共享密钥签名的证明，或让 App 直接向 CF 注册（App Check + 用户身份），Bridge 只做 notify。

**[C-2] [Security: Medium]** `functions/src/index.ts:497-503` ↔ `packages/bridge/src/websocket.ts:1251-1253`
CF 检测到 `registration-token-not-registered` 后删除 Firestore 文档，但**不通知 Bridge**。Bridge 内存中该 token 的 locale / privacy / enabledEventTypes 永久残留：
- 继续为已死 locale 发 `notify`，消耗速率限额；
- `isPrivacyMode()` 被已卸载设备的 `privacy=true` 永久污染；
- `hasExplicitPushSubscriber('session_progress')` 可能被死 token 永久置真，导致 progress 通知无法真正关闭。
- 建议：`notify` 响应体已返回 `deletedInvalidTokens`，扩展为返回被删 token 列表并让 Bridge 清理三张表。

**[C-3] [Security: Medium]** `packages/bridge/src/push-relay.ts:106-112` vs `functions/src/index.ts:74-88, 526-534`
App Check 是**空转的安全控件**：`PushRelayClient.post()` 只发送 `Content-Type` 与 `Authorization`，从不发送 `X-Firebase-AppCheck`。因此 `verifyAppCheck()` 恒返回 false，`ENFORCE_APP_CHECK=true` 一旦开启会 401 掉**所有** Bridge。当前每次调用还会打一条 `logger.warn`，等于给每个请求加了一条噪声日志。
- 建议：要么在 Bridge 侧接入 App Check（Node 端需自定义 provider / debug token），要么移除该分支并改用别的滥用控制，避免形成"以为有防护"的假象。

**[C-4] [Security: Medium]** `packages/bridge/src/websocket.ts:11206-11212, 11090, 11134, 11046`
非隐私模式（默认 `privacyMode = false`）下推送 payload 明文携带：
- `body = msg.result.slice(0, 120)` —— **助手回复正文**；
- `body = msg.error.slice(0, 120)` —— 错误文本（常含路径/栈）；
- `questionText` —— AskUserQuestion 的问题原文；
- `toolName`、`data.toolUseId`；
- title 携带 `sessionLabel()` = 会话名 + **项目目录名**（`projectLabel()`，`websocket.ts:10962-10967`）。

这些经 FCM/APNs 明文中转（对 Google/Apple 可见）并展示在锁屏。未见 token 或凭据泄漏，但正文与路径确实外泄。
- 建议：评估将 `privacyMode` 默认改为 true，或至少在首次开启推送时显式告知并让用户选择。

**[C-5] [Security: Low]** `functions/src/index.ts:513` `onRequest({ cors: true })` 对任意 Origin 开放。需 Bearer token 故非 CSRF，但扩大了浏览器侧滥用面，建议收敛 allowlist。

**[C-6] [Security: Low]** `packages/bridge/src/push-relay.ts:101` 把 `bridgeId`（Firebase UID）打进 stdout；`websocket.ts:4809-4811` 打印 platform/locale/privacy。未打印 token，尚可接受，但 UID 进日志会降低事故排查时的匿名性。

**重放防护结论（正常）**：action 回传不携带任何命令或策略，只带不透明 `permissionId`；`NotificationApprovalRequest` 有 10 分钟 TTL（`_maxAge`）与未来时间上限（`_isTooFarInFuture`），且必须在**当前活连接**的权威 session 快照中命中唯一 pending 才会发送（`_matchingSession` 要求 `matches.length == 1`）。设计正确。

---

## D. 常规 bug

**[D-1] [P1]** `apps/mobile/lib/features/background_sync/background_sync_coordinator.dart:220-224, 431-434` + `apps/mobile/ios/Runner/BackgroundSyncHostPlugin.swift:470-473`
BGAppRefresh 冷启动（进程已被系统回收，由 BGTask 拉起）时 `WidgetsBinding.instance.lifecycleState` 为 `detached`/`null` → `_lifecycleModeFor` 返回 `unknown` → `start()` 与 `_publishDartReadyForLifecycle` 双重门禁都跳过 → **`markDartReady()` 永不调用** → native `refreshController` 停在 `waitingForEndpoint`，25s 后 `setTaskCompleted(success: false)`；而 native 侧注释明确"deliberately do not reschedule here"，Dart 侧的 `scheduleRefresh` 又只在 `_performAppRefresh` 内部调用（本次未执行）→ **BGAppRefresh 永久停摆**，直到用户手动前后台切换一次。
```dart
if (_lifecycleMode != _BackgroundSyncLifecycleMode.unknown) {   // start()
  unawaited(_publishDartReadyForLifecycle(...));
}
```
- 建议：`start()` 时无条件尝试一次 `markDartReady()`（与 lifecycle 解耦），并在 native 的 `handleBackgroundRefreshTask` 失败路径上补一次保守的重排。

**[D-2] [P2]** `apps/mobile/lib/features/claude_session/claude_session_screen.dart:1665,1682` 与 `apps/mobile/lib/features/codex_session/codex_session_screen.dart:2141,2158,2172`
本地通知使用**固定 ID**（approval=1、question=2、complete=3）。多会话并发时，后一个会话的审批通知直接覆盖前一个，用户永久丢失第一个审批入口；而 FCM/背景投影路径用的是 `(sessionId, provider, eventType)` 哈希 ID，两套 ID 空间还会互相产生重复条目。
- 建议：统一为 `hash(provider, sessionId, eventType)`，并抽到一个共享 helper。

**[D-3] [P3]** `apps/mobile/lib/services/notification_service.dart:407-414` + `103-111`
Allow/Reject 按钮文案取自 `PlatformDispatcher.instance.locale`（**系统语言**），而非 App 内设置的 `appLocaleId`；且 `DarwinNotificationCategory` 只在 `init()` 时注册一次，用户在 App 内切换语言后按钮文案不会更新（需重装/重启且系统语言也匹配才行）。
- 建议：用 `SettingsCubit.appLocaleId` 生成文案，并在语言变更时重新 `initialize()` 注册 category。

**[D-4] [P3]** `apps/mobile/lib/services/notification_service.dart:314`
`show()` 开头 `if (!_initialized) return;` 静默吞掉。`init()` 只在 `main.dart:134` 调用一次，若该处抛异常（`getNotificationAppLaunchDetails` 之外的失败）则全应用通知永久无声且无任何日志。建议至少 `logger.warning`。

**[D-5] [P3]** `apps/mobile/lib/features/background_sync/background_notification_mode_controller.dart:515-522`
`_handleNotification` 要求 `_isBackground == true`。在前台↔后台切换瞬间到达的 `background_notification_v1` 会被直接丢弃且不做任何补偿（Bridge 侧已消费掉投影去重状态 `permissionToolUsesBySession`，不会重发）→ 边界事件永久丢失。

**[D-6] [P3]** `apps/mobile/lib/services/notification_approval_coordinator.dart:310-317`
`dispose()` 先 `_retryTimer?.cancel()` 再 `await _sessionSub?.cancel()`；两者之间若 `sessionList` 事件抵达会重新 `_drain()` 并重建 `_retryTimer`，形成一个不会被取消的定时器。建议先取消订阅再取消定时器，或加 `_disposed` 标志位（该类没有）。

**订阅/定时器审计结论（其余正常）**：
- `BackgroundNotificationModeController.dispose()`（:650-666）取消了全部 5 个订阅与 `_disconnectedTimer`；
- `MobileBackgroundSyncCoordinator.dispose()`（:852-862）清理 handler 与 continuation；
- `SettingsCubit.close()`（:718-722）取消 `_tokenRefreshSub` 与 push 超时定时器；
- `main.dart:912-919` 取消 FCM 两个订阅、`_notificationActionSub`、deep link 订阅。

**多客户端 cursor 隔离结论（已实现）**：`backgroundDeliveryClients` 是以 `WebSocket` 为键的 `WeakMap`（`websocket.ts:1266-1269`），每个客户端持有独立的 `projectionState`（`progressBySession` / `permissionToolUsesBySession`），一个客户端的投影去重不会影响另一个；`deltaBatches` 同样按 ws 分桶（:1263），`get_history` 的 `sinceSeq` 由客户端自带（:6730）。**未发现跨客户端水位串扰。** 唯一的共享状态是 FCM 路径的 `notifiedPermissionToolUses` / `progressNotificationState`（:1216-1217），但 FCM 本身是 bridge 级广播，语义上属于同一水位，且在 `stop_session`（:6547）与周期清理（:12166-12173）中被回收，无泄漏。

---

## 优先修复建议排序

1. **A-1**（iOS ISO8601 小数秒）—— 整个长按审批特性目前是死的，改动量最小、收益最大。
2. **A-2**（Bridge 重启后非英文用户完全静默）。
3. **B-1**（Always-Location 模式下 FCM + WS 双投递导致重复通知）。
4. **D-1**（冷启动 BGAppRefresh 永久停摆）。
5. **C-1 / C-3**（推送伪造面 + App Check 空转）。
6. **B-2**（断线后 privacy 永久粘滞）、**D-2**（本地通知 ID 冲突）。
