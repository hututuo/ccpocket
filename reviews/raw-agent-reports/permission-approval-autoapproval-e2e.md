I'll start by exploring the repository structure to understand the codebase layout.
Let me examine the key files and check sizes to plan my reading.
Now let me dig into the Bridge permission source-of-truth code.
Let me delegate Mobile-side mapping in parallel while I continue on Bridge.
I'll do the Mobile investigation myself. First, let me finish the Bridge approval ledger.
已完成端到端只读审查。以下为结果。

---

# 权限 / 审批 / 自动批准 端到端审查报告

审查范围内的一个前置事实先说明：`apps/mobile/lib/features/permission_management/` 是**设备系统权限**（通知/相机/定位/生物识别）宿主，与会话审批权限无关（`permission_host_service.dart:20-41`）。会话权限的 Mobile 侧真正所有者是 `features/chat_session/state/chat_session_cubit.dart` + `chat_session_state.dart` + `services/chat_message_handler.dart`。`codex_core_actions/` 是 compact/review/mcp-status，不参与审批链，仅在 `codex-core-actions.ts:326-332` 读 `permissionRestartInProgress` 做门禁。

---

## A. 权限状态来源账本

### A.0 全部写入点 / 读取点与实际优先级

**Bridge 侧写入点（session.codexSettings 为唯一权威缓存）**

| # | 位置 | 触发 | 写入内容 |
|---|---|---|---|
| W1 | `packages/bridge/src/session.ts:1207-1221` | `create()` | 用 `codexOptions` 全量覆盖（含 undefined 键） |
| W2 | `packages/bridge/src/session.ts:264-308` (`mergeCodexSettings`) → `session.ts:896-905` | 收到任何 `system` 消息（含官方 `init` 的 resolved settings） | 只合并 `!== undefined` 的字段 —— **这一层是正确的** |
| W3 | `packages/bridge/src/websocket.ts:5170-5176` | `set_permission_mode` + `applyStrategy=next_turn` | 全量写 approvalPolicy/reviewer/permissionsMode/sandbox |
| W4 | `packages/bridge/src/websocket.ts:5234-5240` | `set_permission_mode` in-place | 同上 |
| W5 | `packages/bridge/src/websocket.ts:5458-5482` / `6240-6264` | 权限 restart / sandbox restart 重建会话 | 走 W1 |
| W6 | `packages/bridge/src/codex-process.ts:2786-2796` | 官方 `thread/start|resume` 返回 `resolvedSettings` | 写 `_approvalPolicy` / `_runtimeSandboxMode` |
| W7 | `packages/bridge/src/codex-process.ts:879-900` | `thread/settings/update` 成功 | 写 `_approvalPolicy` 等 |

**Bridge 侧读取/对外发布点**

| # | 位置 | 说明 |
|---|---|---|
| R1 | `session.ts:1397-1408` | `list()` 的 `permissionMode`：approvalPolicy 未知 → `undefined`（v01 修复到位） |
| R2 | `session.ts:1362-1375` | `executionMode` 同上 |
| R3 | `websocket.ts:1687-1703, 1798-1825` | `session_created` 只在 `!== undefined` 时带字段（v01 修复到位） |
| R4 | `websocket.ts:2511-2546` | `buildCodexResumeResult`，未知则不带（到位） |
| R5 | **`websocket.ts:5011-5014`** | `set_permission_mode` 读 `process.approvalPolicy`，**该 getter 带 `?? "on-request"` 兜底**（`codex-process.ts:687-689`） |
| R6 | **`websocket.ts:6046-6048`** | `set_sandbox_mode` 读 `session.codexSettings?.sandboxMode ?? "workspace-write"` |
| R7 | `websocket.ts:7303-7314` | resume 读 JSONL factual index（`sessions-index.ts:1413/1421/1460`，只读官方记录，**不回写**，这一层安全） |
| R8 | `local-features/side-chat.ts:1073-1082` | 子会话继承，未知 → `"on-request"` / `"read-only"`（fail-closed，可接受） |

**Mobile 侧**

| # | 位置 | 说明 |
|---|---|---|
| M1 | **`chat_session_state.dart:86-92`** | `permissionMode/executionMode/codexApprovalPolicy/codexPermissionsMode/codexApprovalsReviewer/sandboxMode` **全部有非空默认值，模型里没有 "unknown" 这个状态** |
| M2 | `chat_session_cubit.dart:1002-1076` | `_syncFromSessionSnapshot`，用 `hasPermissionSignals` 门控（到位） |
| M3 | **`services/chat_message_handler.dart:906-968`** | `init/session_created/set_permission_mode` 解析，`hasExecutionSignals` 只要 `permissionMode != null` 即为真 |
| M4 | **`models/messages.dart:437-441`** | `codexApprovalPolicyFromLegacyExecutionMode(null)` → **`onRequest`** |
| M5 | **`models/messages.dart:4395-4397` / `4664-4671`** | `RecentSession.effectivePermissionMode` / `SessionInfo.effectivePermissionMode`：缺失 → 用 `deriveExecutionMode` 兜底 → codex 恒为 `acceptEdits` |
| M6 | `features/session_list/services/session_resume_coordinator.dart:106-158` | `factualCodexResumeSettings`，`approvalPolicy == null` 时全部返回 null（到位） |
| M7 | `session_resume_coordinator.dart:225-231` | 新 Bridge（`CODEX_RESUME_PRESERVES_SETTINGS_CAPABILITY`）时 codex 权限字段全传 null（到位） |
| M8 | `chat_session_cubit.dart:4325-4340`、`4548-4556` | `_SessionSettingsHelper.save(claudeSid, {...})` 持久化到 SharedPreferences；**Codex 会话也在写，但 resume 时 `isCodex` 分支从不读**（写而不读的死数据，见 A7） |

**实际生效的优先级链（Bridge → Mobile 显示）**
```
Mobile 显式 override
  > JSONL factual settings (sessions-index)
  > 不发送，交官方 runtime 解析
  > 官方 system/init resolvedSettings 回填 (W2/W6)
——以上是 v01 设计，Bridge 侧基本落实——
但下游两处把 "未知" 重新折叠成默认值：
  R5/R6（Bridge 自身兜底） 和 M1/M3/M4/M5（Mobile 状态模型无 unknown）
```

---

### A1 【P0 / 已确认根因】Mobile 状态模型没有 "unknown"，任何模式切换都会把发明的 `on-request` 当成用户意图回传 Bridge

- **文件:行号**
  - `apps/mobile/lib/features/chat_session/state/chat_session_state.dart:88-92`（`@Default(CodexApprovalPolicy.onRequest)`、`@Default(CodexPermissionsMode.defaultPermissions)`）
  - `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:4253-4322`（`setSessionModes`）
  - `packages/bridge/src/websocket.ts:859-887`（`codexSettingsFromPermissionsMode`）
- **触发场景**：会话真实权限是 fullAccess（或 custom/profile），但 Mobile 尚未收到权威 settings（首次进入 / resume 未回填 / 旧 Bridge / init 未带 approvalPolicy）。此时用户只是**切了一下 Plan 开关**或 execution 开关。
- **证据**：`setSessionModes` 中
  ```dart
  final codexPermissionsMode = isCodex && state.codexPermissionsMode != custom
      ? state.codexPermissionsMode : null;          // = defaultPermissions（发明值）
  final codexApprovalPolicy = codexPermissionsMode != null
      ? state.codexApprovalPolicy.value : null;     // = "on-request"（发明值）
  ```
  发出 `set_permission_mode{codexPermissionsMode:"default", approvalPolicy:"on-request"}`。Bridge 收到后 `requestedCodexPermissionsMode="default"` → `codexSettingsFromPermissionsMode("default")` 返回 `{approvalPolicy:"on-request", approvalsReviewer:"user", sandboxMode:"workspace-write"}`，因 `newSandboxMode !== currentSandboxMode` 走 restart 路径（`websocket.ts:5215-5221` 的 `canApplyModeInPlace` 为 false），最终 `websocket.ts:5468-5476` 用 `on-request + workspace-write` 重建线程。
- **性质**：这**不是显示问题，是真的把线程权限改回去了**，与用户反馈"权限偶发回到 on-request"完全吻合，且解释了"为什么 v01 修了 Bridge 仍然复现"。
- **建议**：`ChatSessionState` 的 codex 权限字段全部改成 nullable（`CodexApprovalPolicy?` / `CodexPermissionsMode?`），未知即 null；`setSessionModes` 在 codex 权限未知时**只发 planMode/executionMode，不发 approvalPolicy / codexPermissionsMode**；UI 未知态显示占位而非"默认"。

---

### A2 【P0 / 已确认根因】Bridge `set_permission_mode` 的 collaboration-only 分支用 `process.approvalPolicy` 兜底值当作"当前值"回写

- **文件:行号**
  - `packages/bridge/src/codex-process.ts:687-689`
    ```ts
    get approvalPolicy(): string { return this._approvalPolicy ?? "on-request"; }
    ```
  - `packages/bridge/src/websocket.ts:5011-5014`（`currentApproval = normalizeCodexApprovalPolicy(process.approvalPolicy)`）
  - `packages/bridge/src/websocket.ts:5020-5036`（`collaborationOnlyChange` → `explicitApproval = currentApproval`）
  - 写回：`websocket.ts:5170-5176`（next_turn）、`5234-5240`（in-place）、`5468`（restart）
- **触发场景**：`_approvalPolicy === undefined`（resume 未传 override 且官方 `resolvedSettings.approvalPolicy` 缺失 —— `codex-process.ts:2786` 是 `if (resolvedSettings.approvalPolicy)` 真值判断，官方不返回就永远保持 undefined）。用户此时只切 Plan。
- **证据**：`collaborationOnlyChange` 为真 → `newApproval = "on-request"` → 三条落地路径全部把 `session.codexSettings.approvalPolicy = "on-request"` 写死；restart 路径还会真的以 `on-request` 重建 thread。
- **建议**：新增 `get resolvedApprovalPolicy(): string | undefined`（不兜底）供决策路径使用，`approvalPolicy` 的兜底 getter 只留给日志；`collaborationOnlyChange` 时 `approvalPolicy` 传 `undefined`（不发送该字段），让官方 runtime 保留。

---

### A3 【P1 / 已确认根因】sandbox / 权限 restart 后广播的 `session_created` 只带 legacy `permissionMode`，Mobile 据此推导出 `on-request`

- **文件:行号**
  - `packages/bridge/src/websocket.ts:6065-6072`（`executionMode = oldSettings.approvalPolicy === "never" ? "fullAccess" : "default"`，未知 → `"default"`）
  - `packages/bridge/src/websocket.ts:6268-6279` 与 `6354-6366`（`buildSessionCreatedMessage({ permissionMode: legacyPermissionMode, executionMode, ... })`）
  - `websocket.ts:1798-1804`：`approvalPolicy` 因 `undefined` **不会**被带上
  - `apps/mobile/lib/services/chat_message_handler.dart:906-930`：`hasExecutionSignals` 因 `permissionMode != null` 为真
  - `apps/mobile/lib/models/messages.dart:437-441`：`codexApprovalPolicyFromLegacyExecutionMode("default") → onRequest`
- **触发场景**：一个 approvalPolicy 未知的会话，用户切 sandbox 开关（或任何触发 restart 的权限操作）。
- **证据**：Bridge 明确不发 approvalPolicy（正确），但同一条消息带了 `permissionMode:"acceptEdits" + executionMode:"default"`；Mobile 把它当成"有 execution 信号"，于是把 `codexApprovalPolicy` 硬写成 `onRequest`。**Bridge 端的 unknown-preserving 在 Mobile 端被 legacy 字段还原成 on-request。**
- **建议**：Mobile 的 `hasExecutionSignals` 不能把 legacy `permissionMode` 当作 approvalPolicy 信号；`codexApprovalPolicy` 只在 `msg.approvalPolicy != null` 时更新。Bridge 侧 restart 广播在 approvalPolicy 未知时也不应发明 `executionMode`。

---

### A4 【P1 / 高度可疑待验证】`set_sandbox_mode` 用 `?? "workspace-write"` 判等，未知时会静默吞掉用户操作

- **文件:行号**：`packages/bridge/src/websocket.ts:6046-6051`
  ```ts
  const newSandboxMode = sandboxModeToInternal(msg.sandboxMode);
  const currentSandboxMode = session.codexSettings?.sandboxMode ?? "workspace-write";
  if (newSandboxMode === currentSandboxMode) break; // No change needed
  ```
- **触发场景**：真实 sandbox 是 `danger-full-access` 但 Bridge 未知，用户点"沙箱开" → 判定为无变化，直接 `break`，**不回任何消息**，Mobile 的乐观状态与真实值永久分叉。
- **建议**：未知时不能判等，应当实际下发；或先回一条 `sandbox_mode_unknown` 让 Mobile 停止乐观更新。

---

### A5 【P1 / 已确认】列表页与 pending-resume 屏用 `effectivePermissionMode`，把"未知"渲染成 `acceptEdits`（即 on-request 显示）

- **文件:行号**
  - `apps/mobile/lib/models/messages.dart:4389-4397`（`RecentSession.permissionMode` / `effectivePermissionMode`）
  - `apps/mobile/lib/models/messages.dart:4664-4671`（`SessionInfo.effectivePermissionMode`）
  - `apps/mobile/lib/models/messages.dart:470-497`（`deriveExecutionMode` 末尾 `return ExecutionMode.defaultMode`；`legacyPermissionModeFromModes` codex+default → `acceptEdits`）
  - 消费点：`features/session_list/session_list_screen.dart:222`、`:1830`；`widgets/session_card.dart:102`、`:469`
- **证据**：Bridge `session.ts:1397-1408` 已正确返回 `permissionMode: undefined`，但 Mobile 的 getter 立刻用 `??` 把它折叠成 `acceptEdits`。用户从首页点开会话时，顶栏第一眼看到的就是"on-request"。
- **建议**：这两个 getter 返回 `PermissionMode?`，UI 未知态用独立占位（如"读取中"），不要复用 `acceptEdits`。

---

### A6 【P2 / 高度可疑待验证】resume 时 `executionMode` 会被反向映射成 `on-request`

- **文件:行号**：`packages/bridge/src/websocket.ts:7137-7151`
  ```ts
  const requestedApprovalPolicy = msg.approvalPolicy ??
    (msg.executionMode == null ? undefined
      : msg.executionMode === "fullAccess" ? "never" : "on-request");
  ```
- **触发场景**：旧 Mobile（无 `CODEX_RESUME_PRESERVES_SETTINGS_CAPABILITY` 分支）或 `_resumeSessionWithParams` 路径传了 `executionMode:"default"`。此时 `on-failure` / `untrusted` 这类真实策略会被无条件降级为 `on-request`，且优先级高于 `savedApprovalPolicy`（`websocket.ts:7325-7327`）。
- **建议**：`executionMode` 只应影响 `never` 分支；非 fullAccess 时返回 `undefined`，让 factual index / runtime 决定。

---

### A7 【P2】Mobile 对 Codex 会话持久化了权限设置但从不读取（写而不读的污染源）

- **文件:行号**：`chat_session_cubit.dart:4325-4340`、`4548-4556`（`_SessionSettingsHelper.save(claudeSid, {'permissionMode':..., 'executionMode':...})`，Codex 的 `claudeSessionId` 是 thread id）；读取侧 `session_resume_coordinator.dart:206-212` 仅在 `!isCodex` 时 `load`。
- **风险**：目前无害，但一旦有人"顺手"把 Codex 也接上读取，就会立即复现 v01 的默认值污染。
- **建议**：Codex 分支不写，或写入前显式排除未知值。

---

### A8 【P3】`SessionInfo.codexSettings` 在 `create()` 时被全量覆盖（含 undefined 键）

- **文件:行号**：`packages/bridge/src/session.ts:1207-1221`
- **说明**：所有 key 都存在但值为 undefined，导致 `session.ts:1339-1347` 的 `s.codexSettings ?? (process.codexPermissionsMode ...)` 兜底分支**永远不会命中**（对象恒为 truthy）。这条兜底是死代码。当前不造成错误，但是隐性契约漏洞。

---

### A 结论分档

| 判断 | 条目 |
|---|---|
| **已确认根因** | A1（Mobile 无 unknown 态 → 切 Plan/execution 时把发明的 on-request 真的写回线程）、A2（Bridge `approvalPolicy` getter 兜底污染 collaboration-only 分支）、A3（restart 广播的 legacy `permissionMode` 在 Mobile 端被还原成 on-request）、A5（列表/pending 屏显示折叠） |
| **高度可疑待验证** | A4（sandbox 未知判等吞操作）、A6（resume executionMode 反向映射） |
| **需真机事件线** | 到底是"仅显示"还是"真改"，取决于用户复现时是否点过 Plan/sandbox。抓取顺序建议：① `[codex-process] Starting app-server (... approval: ...)`；② `resolvedSettings` 是否含 `approvalPolicy`；③ `[ws] set_permission_mode(codex): ... → approval=` 一行；④ Mobile 侧 `setSessionModes execution=... plan=...` 日志。四条对齐即可闭环 A1/A2。 |

---

## B. 审批生命周期

### B1 【P0 / 已确认根因】Plan 审批（`pendingPlanCompletion`）只存在于 CodexProcess 内存，且不是官方 pending request——权限/沙箱 restart 会永久丢失它

- **文件:行号**
  - `packages/bridge/src/codex-process.ts:4331-4348`（合成 `plan_<uuid>` 的 `permission_request`，仅写 `this.pendingPlanCompletion`）
  - `packages/bridge/src/codex-process.ts:612`（字段声明）
  - `packages/bridge/src/websocket.ts:5453`（`this.destroySession(oldSessionId)`）、`websocket.ts:6240-6264`（sandbox restart 同样重建）
- **触发场景**：Plan 首次退出弹出审批 → 用户不选，去改权限或沙箱 → Bridge 销毁并重建会话 → 该 Plan 审批彻底消失，且 `_collaborationMode` 在新进程里由 `collaborationMode` 参数恢复为 plan，会话卡在"计划已生成但无法执行"。
- **证据**：`pendingApprovals`（有 requestId，可回官方）与 `pendingPlanCompletion`（纯合成）是两套东西；后者没有任何持久化或跨进程交接。
- **建议**：restart 前把 `pendingPlanCompletion` 连同 planText 一起转交新会话（作为 Bridge-level ledger），或在 restart 前明确回一条 `permission_resolved` + tip，让用户知道计划审批已作废。

### B2 【P1 / 已确认】`stop()` 不清 `pendingPlanCompletion`，且清空 `pendingApprovals` 时**不发 `permission_resolved`**

- **文件:行号**：`packages/bridge/src/codex-process.ts:1849-1868`（`stop()` 清了 `pendingApprovals` / `pendingUserInputs`，没有 `pendingPlanCompletion = null`）；`codex-process.ts:1925-1935`（`prepareLaunch()` 才清）；`codex-process.ts:1972-1975`（transport exit 只 `rejectAllPending`）
- **后果**：
  1. `stop()` 后 `getPendingPermission()`（`codex-process.ts:2365-2380`）仍返回 ExitPlanMode → `session.ts:1361` 继续把僵尸审批塞进 `session_list.pendingPermission` → Mobile `_restoreRuntimeInteractions` 反复恢复一个死审批。
  2. 进程重启/退出时被清空的普通审批**没有终态事件**，Mobile 卡片一直挂着，直到下一次 history 重放。
- **建议**：`stop()` / `prepareLaunch()` / transport exit 统一对每个被清掉的 toolUseId 发 `permission_resolved`（带 `reason: "runtime_reset"`），并把 `pendingPlanCompletion` 一起清。

### B3 【P1 / 已确认】`getPendingPermission()` 只暴露一条，Plan 优先，其余待处理交互在 `session_list` 中不可见

- **文件:行号**：`packages/bridge/src/codex-process.ts:2365-2390`（plan → 第一条 approval → 第一条 userInput）；`session.ts:1348-1361`；`SessionSummary.pendingPermission` 为单值（`session.ts:229-233`）
- **后果**：Plan 审批 + 另一条工具审批同时存在时，退出页面再进入只能恢复 Plan；另一条要等 canonical history 重放才可能回来。这正是 v01 8.2 记录的"其他待处理问题一并隐藏"，**当前仍未解决**（Bridge 侧只解决了 `waiting_approval` 状态门控，没解决单值问题）。
- **建议**：`SessionSummary` 增加 `pendingPermissions: [...]`（旧客户端继续读单值字段）。

### B4 【P1 / 已确认】通知里的 Allow/Reject 依赖 `session_list.pendingPermission` 匹配，但 Bridge 在审批产生时**不广播 session_list**

- **文件:行号**
  - `apps/mobile/lib/services/notification_approval_coordinator.dart:262-285`（`_matchingSession` 要求 `session.pendingPermission?.toolUseId == request.permissionId`）
  - `packages/bridge/src/websocket.ts` 全部 30 处 `broadcastSessionList()` 中**没有一处由 `permission_request` 或 `status=waiting_approval` 触发**；`session.ts:1401-1412` 的 `onSessionUpdated` 只在 `claudeSessionId` 变化 / `codexSettingsChanged` / `runtime_capabilities` 时触发
  - `notification_approval_coordinator.dart:209-258`（`_drain` 只监听 `sessionList`/`connectionStatus`，自身不调 `requestSessionList()`）
  - TTL：`notification_approval_coordinator.dart:148`（`_maxAge = 10 分钟`）
- **后果**：从通知长按 Allow 时，若当前 `_bridge.sessions` 快照没有该 pending（很常见：审批刚产生、App 在后台），请求排队 → 10 分钟后静默过期 → **用户以为批准了，Bridge 从未收到**。叠加 B3，非首条审批更是永远匹配不上。
- **建议**：`permission_request` 产生时 Bridge 主动 `broadcastSessionList()`；`_drain` 在无匹配且已连接时主动 `requestSessionList()` 一次。

### B5 【P2 / 已确认】Mobile 侧仍保留"最后一条状态不是 waiting_approval 就清空 pending"的门控

- **文件:行号**：`chat_session_cubit.dart:4153-4176`
  ```dart
  if (lastStatus != ProcessStatus.waitingApproval) {
    _pendingPermissionRequests.clear();
  }
  ```
- **说明**：v01 把这条门控从 Bridge 拿掉了，但 Mobile 端同样的逻辑还在。当前被 `_restoreRuntimeInteractions`（`chat_session_cubit.dart:1770-1776`、`1626-1628`）在其后补救，所以"多数情况"能恢复；一旦 `_bridge.sessions` 快照过期（见 B4），补救失效，`_emitNextApprovalOrNone` 也就找不到下一条 pending。
- **建议**：以 runtime ledger 为唯一权威，history 只用于补充不用于清空。

### B6 【P2 / 已确认】`_restoreRuntimeInteractions` 只对 Codex 生效，Claude 的 ExitPlanMode 退出页面后不恢复

- **文件:行号**：`chat_session_cubit.dart:1180-1181`（`if (!isCodex || isClosed) return;`）；Bridge 侧 `session.ts:1348-1361` 对 `SdkProcess` 同样暴露 `getPendingPermission`
- **建议**：去掉 provider 限制，或明确记录为 Claude 已知缺口。

### B7 【P2 / 已确认】外部 Desktop continuity 的 idle 事件无条件清空审批卡

- **文件:行号**：`chat_session_cubit.dart:794-802`（`_finishExternalDesktopTurn`）、`chat_session_cubit.dart:1592-1600`（快照 idle 分支）——两处都 `approval: const ApprovalState.none()`，且**不跟一次 `_restoreRuntimeInteractions`**，只靠随后异步的 `requestSessionHistory`。
- **后果**：手机 + Desktop 同时开同一 thread 时，Plan 审批可能被 Desktop 的 idle 事件抹掉并有 900ms~数秒空窗。

### B8 【P2 / 已确认】approve/reject 是本地乐观终态，Bridge 未收到时无任何回补

- **文件:行号**：`chat_session_cubit.dart:4064-4072`（先 `_markToolUseResponded` 再 `send`）、`4204-4212`；`bridge_service.dart:3760-3764`（512 条上限）；离线走 `bridge_service.dart:2527-2551` 队列
- **后果**：Bridge 重启后 replay 的 approve 打到不存在的 toolUseId，`codex-process.ts:2177-2183` 只打日志；Mobile 已经把它标成 responded（`_respondedToolUseIds`），`_restoreRuntimeInteractions:1188` 会跳过恢复 → 审批彻底消失、Agent 侧仍在等。
- **建议**：`approve/reject` 引入 requestId + Bridge ack（复用已有的 `permissionChangeId` 模式），未 ack 前不进入 responded 集合。

### B 结论分档

| 判断 | 条目 |
|---|---|
| **已确认根因（(b) 残留）** | B1（restart 丢 Plan 审批 —— v01 的 "pending ledger" 并不持久）、B3（单值 pendingPermission 隐藏其余审批）、B4（通知审批因 session_list 不刷新而静默过期） |
| **高度可疑待验证** | B2、B5、B7（都能造成"审批消失"，但需要真实时序确认哪一条先命中） |
| **需真机事件线** | 用户复现"Plan 首次退出未选择后审批消失"时，需要：① Bridge 日志有无 `Permission mode change: destroyed session` / `Sandbox mode change`（命中 B1）；② Mobile 是否走了通知 Allow（命中 B4）；③ 退出页面到再进入之间是否收到过 `session_list`（命中 B5）。 |

---

## C. 自动批准

当前实现**不是规则引擎**，而是"按 thread 的总开关 + 一份危险命令否决表"。权威在 Bridge（`packages/bridge/src/local-features/auto-approval.ts`），Mobile（`features/auto_approval/auto_approval_service.dart`）只是控制面，不在手机上做任何匹配判断——这个分层是正确的。持久化：`~/.ccpocket/auto-approval-v1.json`，0600，原子 rename（`auto-approval.ts:181-200`）。

### C1 【P1 / 安全：权限提升】`Permissions` 与 `FileChange` 无条件放行

- **文件:行号**：`packages/bridge/src/local-features/auto-approval.ts:495-498`
  ```ts
  case "FileChange":
  case "Permissions":
  case "ExitPlanMode":
    return true;
  ```
  对应请求源：`packages/bridge/src/codex-process.ts:3798-3822`（`item/permissions/requestApproval` → toolName `Permissions`，input 含 `permissions`）；响应构造 `codex-process.ts:5016-5028`
  ```ts
  if (pending.kind === "permissions") {
    return { scope: ..., permissions: decision === "decline" ? {} : (pending.requestedPermissions ?? {}) };
  }
  ```
- **问题**：`Permissions` 是 **Agent 自己请求扩权**（网络、沙箱放宽等）的通道，自动批准会把 Agent 请求的权限**原样授予**，完全没有用户环节。`FileChange` 同理无条件放行，包括带 `grantRoot`（`codex-process.ts:3737-3745`）的"新增可写根目录"请求。
- **建议**：`Permissions` 一律排除出自动批准；`FileChange` 携带 `grantRoot` 时排除。

### C2 【P1 / 安全：匹配可绕过】重定向被剥离 + 解释器不在否决表

- **文件:行号**：`auto-approval.ts:595-608`（`__ccpocket_redirection__` 占位）与 `auto-approval.ts:611-617`（`segmentRequiresManualApproval` 直接跳过占位及其后一个词）；否决表 `auto-approval.ts:694-704`（`rm/rmdir/unlink/shred/srm/dd/diskutil/mkfs*`）
- **误放行样例**（均判定为可自动批准）：
  - `echo x > ~/.ssh/authorized_keys`、`: > important.db` —— 重定向被整体丢弃，只剩 `echo`
  - `python3 -c "import shutil; shutil.rmtree('/x')"`、`node -e "..."`、`perl -e "..."` —— 解释器不在否决表且无 `-c` shell 递归处理
  - `mv`、`chmod`、`chown`、`ln -sf`、`truncate`、`install` 均不在否决表
- **对比**：`sudo/env/nice/xargs/find -exec/bash -c` 的包装解包做得相当扎实（`auto-approval.ts:713-760`），`curl | bash` 也正确 fail-closed，说明设计意图是白名单外拦截，但实际是黑名单，覆盖不全。
- **建议**：把重定向目标当作写操作参与判断；把常见解释器（python/node/perl/ruby/php/osascript）与 `mv/chmod/chown/ln/truncate/tee` 加入需人工审批；或改为"仅放行显式只读命令白名单"。

### C3 【P2】`ExitPlanMode` 自动批准会与 (b) 交互

- **文件:行号**：`auto-approval.ts:497`
- **说明**：开了自动批准的会话，Plan 审批会在 `queueMicrotask` 里被自动批准（`auto-approval.ts:322-330`），用户根本看不到"Plan 退出确认"。若用户不知道自己开着自动批准，现象就是"Plan 审批消失"——与 (b) 症状**完全一致**，容易误诊。排查 (b) 时**必须先确认该会话是否在 `~/.ccpocket/auto-approval-v1.json` 里**。

### C4 【P2】Bash 的 `proposedExecpolicyAmendment` / `proposedNetworkPolicyAmendments` 不参与危险判定

- **文件:行号**：`auto-approval.ts:487-493` 只看 `input.command`；请求侧 `codex-process.ts:3690-3714` 明确会带 `proposedExecpolicyAmendment`
- **后果**：一个命令本身看着无害、但同时附带"永久放宽 execpolicy"的批准，会被自动放行。

### C5 【P3 / 一致性】Mobile 与 Bridge 不一致时的行为是安全的

- **文件:行号**：`auto_approval_service.dart:75-88`（`canConfigureSession` 要求 Bridge 已连接且 capability 支持）、`:150-166`（`disableAll` 先本地置位 `_globalDisablePending` 再排队下发）、`auto-approval.ts:51-58`（`isActive` 同时检查 `disableAllPending` 与 `settingIntents`）
- **评价**：紧急停止是 fail-safe 方向（先禁用后同步），legacy import 只在 Bridge 未配置时生效（`auto-approval.ts:113-126`），设计正确。唯一小问题：开关键是 **thread id**，fork/rewind 产生新 thread 后自动批准不会跟随（可能是有意的，建议在文档里明确）。

---

## D. 安全视角

### D1 【P1 / 安全：授权缺失】`approve/reject/answer` 没有任何请求方身份，且 `sessionId` 可省略后落到任意会话

- **文件:行号**：`packages/bridge/src/websocket.ts:6382-6392`、`6470-6483`、`6485-6497`（全部只做 `resolveSession(msg.sessionId)`）；`websocket.ts:9595-9606`
  ```ts
  private resolveSession(sessionId: string | undefined) {
    if (sessionId) return this.sessionManager.get(sessionId);
    return this.getFirstSession();      // = 列表最后一个会话
  }
  ```
  再叠加 `codex-process.ts:2408-2413`：
  ```ts
  private resolvePendingApproval(toolUseId?: string) {
    if (toolUseId) return this.pendingApprovals.get(toolUseId);
    const first = this.pendingApprovals.values().next();   // 任意一条
    ...
  }
  ```
- **风险**：任何连上 WS 的客户端可以对**任意会话**发 approve；省略 `sessionId` + 省略 `id` 时会批准"某个会话的某条审批"。唯一防线是 `BRIDGE_API_KEY`（`websocket.ts:1549-1556`），而按 CLAUDE.md 该变量**默认未设置**、`BRIDGE_HOST` 默认 `0.0.0.0`。这就是 v01 11.2 记为"待部署"的那条边界，在审批面上后果最严重。
- **建议**：`approve/reject/answer` 强制要求 `sessionId` 与 `id`（缺失即 400），去掉 `getFirstSession()` 兜底；连接建立时绑定设备身份，审批动作校验绑定。

### D2 【P1 / 安全】自动批准的写文件能力可反向修改自动批准状态文件

- **文件:行号**：`auto-approval.ts:829-839`（状态文件 `~/.ccpocket/auto-approval-v1.json`；`CCPOCKET_AUTO_APPROVAL_STATE_FILE` 可被环境变量重定向）；`auto-approval.ts:140-143`（`ensureLoaded` 用 `loadPromise ??=`，进程内只读一次）
- **链条**：会话 A 开了自动批准 → C2 的重定向绕过让 Agent 能写任意文件 → 写入 `~/.ccpocket/auto-approval-v1.json` 追加其他 thread id → Bridge 下次启动后其他会话也自动批准。
- **缓解现状**：内存只加载一次，所以不会立即生效；文件权限 0600 但 Agent 就是同一用户。
- **建议**：状态文件路径加入 Bridge 的写保护黑名单（`FileChange` 请求命中该路径时强制人工审批），并在每次 `isActive` 前校验 mtime/inode 变化。

### D3 【P2 / 安全】`approve_always` 对 `Permissions` 请求授予的是 session 级永久权限

- **文件:行号**：`packages/bridge/src/codex-process.ts:5019-5022`（`scope: decision === "acceptForSession" ? "session" : "turn"`）
- **说明**：UI 上"始终允许"对普通工具是便利功能，对 `Permissions` 类请求则等于把 Agent 请求的扩权固化到整个会话。建议在 UI 上对 `toolName === "Permissions"` 隐藏"始终允许"。

### D4 【P3 / 安全：良好实践，确认无问题】

- 通知审批链是当前最严谨的一条：`notification_approval_coordinator.dart:262-285` 同时校验 `toolUseId + provider + (runtime sessionId 或 providerSessionId)`，用 ephemeral 投递避免离线重放（`models/messages.dart:5218-5225`、`5247-5254`），并有 10 分钟 TTL 与"未来时间"防护（`:278-286`）。**不存在伪造他人 toolUseId 的路径**（前提是 D1 的传输层身份补齐）。
- `sessions-index.ts:1413/1421/1460` 只从官方 JSONL 读取 factual settings，Bridge 从不回写权限到持久层 —— **A 部分要求排查的"unknown 写回持久层"在 Bridge 侧不存在**，唯一残留是 Mobile 的 A7（写而不读）。
- `rejectDuringPermissionRestart`（`websocket.ts:6388/6461/6476/6491`）正确阻止 restart 期间的审批动作。

---

## 建议的修复顺序

1. **A1 + A2**（同一个根因的两端）：Mobile 状态模型引入 unknown + Bridge 去掉决策路径上的 `?? "on-request"`。这一条修完，(a) 的"真的被改回去"就断了。
2. **A3 + A5**：Mobile 停止把 legacy `permissionMode` 当 approvalPolicy 信号 / 停止把未知折叠成 `acceptEdits`。这一条修完，(a) 的"显示回退"也断了。
3. **C1 + C2**：自动批准排除 `Permissions`/`grantRoot`，重定向与解释器纳入危险判定。
4. **B1 + B3 + B4**：Plan pending 跨 restart 交接、`pendingPermissions` 改数组、审批产生时广播 session_list。
5. **D1**：`approve/reject/answer` 强制 sessionId + id，删除 `getFirstSession()` 兜底。

排查 (b) 前请先排除 C3（该会话是否开着自动批准），否则会把自动批准的正常行为误判成 bug。
