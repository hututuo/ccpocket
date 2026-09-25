# CC Pocket 三条错误反馈链审查（v02）

日期：2026-09-25
基线：`main @ 29691b76`

## 结论

三条链都存在生产代码和测试基础，但都不能标记为“已完整证明”。本次审查确认了一个会直接造成用户“操作无响应”的生产缺陷，并已修复：detached/shared 会话原先只接收有限错误码，新增或未列入白名单的 scoped error 会被丢掉。

另外两个高风险问题属于测试/证据链设计缺陷，也已先收紧门禁：真实 rollout 缺失时默认报告 BLOCKED；真实 Bridge 测试必须按 revision 和 windowComplete 等待，不能只按条目数量；最新 turn gap 测试纳入统一脚本；诊断敏感字段拒绝现在返回脱敏的类别和路径，磁盘容量探测失败与磁盘不足分开。

完整的 shared runtime、断线重连、真实设备回执和 Flutter Widget 挂载仍需依赖可运行工具链/真机，不能用静态或数量测试冒充完成。

## 三条链台账

| 链 | 当前结果 | 已确认边界 | 本次处理 |
|---|---|---|---|
| 实时错误反馈 | PARTIAL → 改善 | Bridge 仍有大量 direct error 构造缺少统一 code/owner；detached 旧 allow-list 会吞掉未知 scoped error；错误可能同时进入 runtime 和 history | detached 会话改为接收所有明确拥有该 thread 的 `ErrorMessage`；会话广播补 `errorEventId/errorSource/sessionId`；Mobile 按事件 ID 去重；新增回归测试 |
| 电脑端真实接收端 | PARTIAL | Bridge/SQLite/Cubit/layout 多数使用生产实现，但 harness 仍绕过部分原始 JSON-RPC、未挂载生产 updater，未覆盖 shared/reconnect/fault injection；旧测试按 count 等待可假绿 | 等待条件加入 revision/windowComplete；脚本纳入 latest-gap；rollout 缺失默认 BLOCKED |
| 诊断取证上传 | PARTIAL | 成功归档/receipt 基本可靠；断线后的 terminal failure 没有 durable tombstone；敏感拒绝只有笼统文本；capacity null 被误报为没空间 | 敏感字段错误增加安全 category/path；手机区分 `storage_capacity_unknown` 与 `insufficient_storage`；失败 tombstone/重连查询仍列为后续 P1 |

## 生产链事实

### 1. 实时错误反馈

- Bridge 的 `ErrorMessage` 在经过 `broadcastSessionMessage` 时通常能补 session owner，但大量 websocket direct-send 路径仍未统一生成 `errorCode` 和 `sessionId`。
- Mobile `BridgeService` 当前会把无 owner 的错误留在全局流，不再广播到所有会话；这是必要的隔离，但没有 owner 的请求错误仍可能只表现为全局诊断。
- detached/shared 会话以前在 `chat_session_cubit.dart` 只订阅 `_isDetachedControlResponse`，它是按已知错误码维护的白名单。该模型不能随着新错误安全扩展，已改为“所有 `ErrorMessage.sessionId == 当前 durable thread` 都进入统一错误 reducer；非错误控制消息仍按原控制筛选”。
- runtime error 与 canonical history 的重复投影、eventId/operationId 缺失仍需要后续统一事件模型处理；本次没有把错误直接从历史中粗暴删除。

### 2. 电脑端真实接收端

当前链路应保持以下边界：

```text
fake Provider/app-server RPC
  → 真实 Bridge/WebSocket
  → 真实 Dart BridgeService
  → 真实 SQLite staging/commit
  → 真实 Cubit/timeline layout
  → receiver traces
```

固定 raw-frame replay 只能证明 Mobile 解码；fake historyReader 的 real-Bridge 测试不能证明原始 Provider 通知解析；直接调用 `handleNotification` 不能证明真实 JSON-RPC envelope。它们必须被标注为互补证据，不能合并成“全链路已通过”。

本次把真实 Bridge 测试的等待条件从“entry count 相同”收紧为：

- timeline update 的 `revision` 非空；
- SQLite window revision 与该 update revision 相同；
- `windowComplete` 与场景预期相同；
- entry count 与当前 step 相同。

## 本次修改

- `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart`
  - detached/shared 会话不再依赖错误码白名单接收错误。
  - 明确 scoped owner 后，未知 error code 也进入同一错误处理路径。
  - 对带 `errorEventId` 的错误做有界去重，避免 live/replay 产生第二个错误气泡。
- `packages/bridge/src/parser.ts`、`packages/bridge/src/websocket.ts`
  - `ErrorMessage` 增加稳定事件 ID、操作 ID、来源和阶段字段。
  - 会话广播边界自动补齐 owner、事件 ID 和 Bridge 来源；没有会话归属的 direct error 仍留在全局/请求通道。
- `apps/mobile/test/chat_session_cubit_test.dart`
  - 新增未登记 scoped error code 的 detached 回归测试。
- `scripts/test-conversation-chain.sh`
  - `CCPOCKET_REAL_CHAIN=auto` 找不到冻结 rollout 时返回 BLOCKED（退出码 2），不再静默跳过。
  - 纳入 `conversation_latest_turn_gap_receiver_test.dart`。
- `apps/mobile/test/blackbox/conversation_real_bridge_chain_test.dart`
  - 等待当前 revision/windowComplete，不再只凭数量读取旧快照。
- `packages/bridge/src/file-transfer-diagnostic.ts`
  - 敏感字段仍 fail-closed，但返回不含值的 `category` 和受限 `path`，便于定位。
- `apps/mobile/lib/features/file_transfer/file_transfer_service.dart`
  - capacity probe 返回 null 时使用 `storage_capacity_unknown`，不再误报 `insufficient_storage`。
- `apps/mobile/lib/features/file_transfer/file_transfer_strings.dart`
  - 增加该新错误码的用户提示，并标记为可重试。
- `apps/mobile/lib/features/diagnostics/session_diagnostic_report.dart`
  - 页面在上传等待期间被销毁时不再静默丢弃最终结果；无 UI 宿主时保留带阶段/错误码的 debug 记录，授权阶段明确失败。

## 未解决但已明确的 P1

1. Bridge 统一 `sendSessionError`/`sendGlobalError`，为 session-owned direct errors 强制注入稳定 `errorCode`、`sessionId`、`operationId`。
2. 增加 error event identity，并定义 runtime error 与 canonical history 的单写入规则或 eventId 去重规则。
3. 诊断上传增加 durable failure tombstone 和重连查询/重放；目前成功 receipt 可重放，terminal failure 仍可能在 WebSocket 断开时只剩超时。
4. Headless runner 接入生产 `DurableSessionPreviewUpdater`，并真正关闭/重新打开 SQLite 后再构造 Cubit；加入丢帧、重复、乱序、迟到、旧 generation、断线重连和 shared runtime 场景。
5. 让 headless trace 有独立 oracle verifier，逐阶段核对 provider item ID、turn、revision、stable key、ACK-after-commit 和最终布局，而不是只由测试代码临时计算期望。

## 验证状态

- `git diff --check`：PASS。
- Dart/Flutter/Vitest：当前执行环境缺少 `flutter`、Dart `.dart_tool`、Bridge `node_modules/tsc`，本轮为 BLOCKED/NOT RUN，不伪称通过。
- 未部署 Bridge、未构建 IPA、未安装真机、未触碰生产会话。
