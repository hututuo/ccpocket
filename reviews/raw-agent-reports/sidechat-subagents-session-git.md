I'll start by exploring the repository structure to understand the codebase layout.
Let me delegate the large git review while I dig into Side Chat myself.
Now let me dig into Side Chat lifecycle myself.
# Side Chat / 子 Agent / session_* / Git 只读审查报告

审查基线：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725`（未修改任何文件）。`auxiliary_floating_dock.dart` 已按要求排除。

---

## A. Side Chat 生命周期取证

### [A-0] 结论先行（取证结果）

| 交接文档要求 | 核对结论 |
|---|---|
| 使用官方 `thread/fork(ephemeral:true)` | ✅ **属实**。`codex-process.ts:2698-2705` 明确 `method = "thread/fork"`、`threadParams.ephemeral = options?.ephemeralForkFromThreadId != null`；`codex-process.ts:2745-2761` 还对返回值做了三重契约校验（新 id ≠ 父 id、`thread.ephemeral === true`、`thread.path === null`），不满足就拒绝且**不做 `thread/delete`**（注释明确说明理由），这段写得很稳。 |
| 不硬编码半小时/1800/30 分钟 | ✅ **属实，全域搜索无命中**。`side_chat/` + `subagents/` + `local-features/` 下唯一的时间常量是请求握手超时：`OPEN_TIMEOUT_MS = 10_000`（`side-chat.ts:25`）、Mobile `requestTimeout` 12s/15s。无任何 TTL / expire / maxAge / lifetime 逻辑。 |
| 不新造持久会话类型 | ⚠️ **有残留违规**，见 [A-6]。 |
| 关闭 UI 后 registry 保留入口 | ⚠️ **registry 保留了，但主入口不复用**，见 [A-3]，这是本组最严重的问题。 |
| registry 与真实 Bridge 存活状态对账 | ❌ **完全没有对账**，见 [A-1]/[A-2]。 |

---

### [A-1] [P0] `packages/bridge/src/session.ts:1149-1175, 2380-2406` + `websocket.ts:2371-2375` — ephemeral child 进程退出后会话永不销毁，registry 长期展示已死会话

- **问题**：`proc.on("exit")` 只把 `session.status` 置为 `"idle"`，**不从 `this.sessions` 删除**；而 `evictStaleIdleSessions()`（2380-2398）与 `idleSessionCount()`（2400-2406）都显式排除 auxiliary：
  ```ts
  .filter((session) => session.status === "idle" && !session.auxiliary)
  ```
  `listEphemeralSideChats()`（session.ts:1443-1452）只按 `auxiliary?.kind` 过滤，**不检查进程是否存活**。`destroy()` 只有三个调用点：显式 `close_ephemeral_side_chat`、父会话级联、`destroyAll()`。
- **触发场景**：child 的 codex app-server 崩溃 / 机器休眠 / bootstrap 失败退出 → registry 仍返回该 entry，`status: "idle"`，与健康的空闲侧聊天**在 UI 上完全无法区分**。用户点进去，`CodexSessionScreen` 正常渲染，输入却发给一个已死进程。
- **额外恶果**：ephemeral 线程是 in-memory 的（`thread.path === null`），进程一死转写就永久不可恢复，**没有任何 rehydrate 路径**（`rehydrateCodexSessionAfterExternalTurn` 只对 durable thread 有效）。
- **建议**：`listEphemeralSideChats()` 增加存活探测（`process.isAlive` / 未 exit 标志）；在 `proc.on("exit")` 中对 `session.auxiliary?.kind === "ephemeral_side_chat"` 直接 `destroy(id)` + `broadcastEphemeralSideChatRegistry()`；或在 descriptor 中带 `alive: boolean` 让 Mobile 区分。

### [A-2] [P1] 同上 — 死会话永久占用 8/4 配额，且客户端断开也不回收

- **证据**：`websocket.ts:2308-2318` 的硬上限：全局 `allChildren.length >= 8`、单父 `>= 4`。配额基于 `listEphemeralSideChats()`，即包含 [A-1] 的僵尸条目。另外 `EphemeralSideChatFeatureHandler` **没有实现 `disconnect(client)` 也没有 `close()`**（对比 `side-chat.ts:186` 与 `subagents.ts:151` 都有）——这是"关闭 UI 后仍能找回"的设计意图，但代价是手机 App 被杀死后，child 会话（每个都是一个独立 `CodexProcess` = 一个 codex app-server 进程）会一直驻留到 Bridge 重启。
- **后果**：累计 8 个僵尸后，`open_ephemeral_side_chat` 永久返回 `"Bridge has reached the ephemeral side chat limit"`，用户在 App 内没有任何界面能清掉别的父会话下的僵尸。
- **建议**：为 auxiliary 会话设计独立的空闲回收策略（例如"进程已退出"或"超过 N 分钟无客户端订阅且 idle"），或至少让配额只统计存活会话。

### [A-3] [P1] `apps/mobile/lib/features/side_chat/widgets/ephemeral_side_chat_pane.dart:92-108` + `local_session_features/slots/side_chat_ui_slot.dart:20-49, 52-55` — 关闭面板后从菜单重开 = **再 fork 一个新 child**，而不是找回已存活的那个

- **证据**：`_resolveOrOpen()` 只有在 `widget.childSessionId != null` 时才尝试复用：
  ```dart
  final existingId = widget.childSessionId;
  if (existingId != null) { ...entryForChild(existingId)... return; }
  _opening = true;
  unawaited(_open(generation));      // 无条件 registryService.open() = 新 fork
  ```
  而全仓库只有 **一处** 传 `childSessionId`：`codex_session_screen.dart:1922`（悬浮小窗的再进入路径）。`side_chat_ui_slot.dart` 的 `overflowActions`（22-29）和 `selectionActions`（32-49）走的 `openPane` **都不带 `childSessionId`**，且 `paneDescriptor` 明确 `rememberPerSession: false`（第 55 行）。
- **触发场景**：打开侧聊天 → 关闭面板 → 从菜单再开 → 得到 child#2（旧的还活着）。重复 4 次后第 5 次报 `"This conversation has reached the side chat limit"`，用户完全不知道自己制造了 4 个孤儿。
- **这正是"重开"状态项的核心缺口**：registry 侧的保留是对的，缺的是"主入口优先复用同父下最新存活 child"这一步。
- **建议**：`_resolveOrOpen()` 在 `childSessionId == null` 时先查 `registryService.entriesForParent(parentSessionId)`，非空则复用最新一条（或给出"复用 / 新建"选择），只有为空时才 `open()`。

### [A-4] [P2] `ephemeral_side_chat_pane.dart:81-108, 132-148, 246-251` — 从悬浮小窗进入的面板，一旦 child 消失，"重新打开"按钮永久无效（死胡同）

- **证据**：child 从 registry 消失时 `_registryChanged` 置 `_error`；重试按钮 `onPressed: _resolveOrOpen`，而 `_resolveOrOpen` 读的还是**固定不变的** `widget.childSessionId`（旧的死 id）→ `entryForChild` 恒为 null → `_error = ''` → 再次显示失败。循环无出口。
- **触发场景**：Bridge 重启 / child 被别的客户端关闭 → 用户点重试 N 次都失败，只能退出整个面板。
- **建议**：重试时若 `entryForChild(widget.childSessionId) == null`，降级为"开新的 ephemeral child"（清掉本地记忆的 childSessionId 再走 `open()`）。

### [A-5] [P2] `ephemeral_side_chat_pane.dart:86-91` — 能力协商竞态会**永久**降级到旧的自造聊天实现

- **证据**：
  ```dart
  if (!widget.registryService.isSupported) { _useLegacyFallback = true; ... return; }
  ```
  `isSupported` 读的是 `_bridge.capabilities`（即时快照）。若面板在 WebSocket 尚未完成能力协商 / 处于断线时打开，就一次性钉死 `_useLegacyFallback = true`；而 `_registryChanged` 第 133 行 `if (!mounted || _useLegacyFallback) return;` **永不复位**。
- **后果**：用户拿到的是 `SideChatPanel`（553 行自造聊天渲染，见 [C-2]），而不是产品要求的官方会话 UI，且直到重开面板都不会恢复。
- **建议**：`_useLegacyFallback` 只在 Bridge 已连接且明确回了 `unsupported_capability`/`unsupported_bridge` 时才置位；断线/未协商时进入等待态并监听能力变化。

### [A-6] [P2] `packages/bridge/src/websocket.ts:2193-2280, 1447-1448` + `local-features/persisted-side-chat.ts` + `apps/mobile/.../persisted_side_chat_pane.dart` — "持久侧聊天"这套**新造的持久会话类型**代码仍在仓库里，且 Bridge 侧的创建函数无任何上限

- **证据**：
  - `createPersistedCodexChildSession` 走的是 `forkFromThreadId`（**非 ephemeral**，2234 行），创建的是真正的持久会话；它**没有 8/4 上限、没有 `parent.auxiliary` 守卫**（对比 ephemeral 版 2299/2308-2318 都有），可以无限创建、还能对 child 再 fork child。
  - 该函数已经挂进 runtime（`websocket.ts:1447`）。
  - 但 `local-features/slots/side-chat.ts:8` 只注册了 `SideChatFeatureHandler` 与 `EphemeralSideChatFeatureHandler`，**`PersistedSideChatFeatureHandler` 未注册** → 当前不可达。
- **判定**：目前是"已停用但完整保留的死代码"，直接违反交接文档"不新造持久会话类型"，且一旦有人补一行 registry 注册就是不设防的会话工厂。Mobile 侧 `persisted_side_chat_pane.dart`（246 行）同样无任何引用方。
- **建议**：整体删除 persisted-side-chat 相关的 Bridge handler / protocol slot / runtime 方法 / Mobile pane；若必须保留，至少补上与 ephemeral 一致的上限与 auxiliary 守卫。

### [A-7] [P2] `packages/bridge/src/ephemeral-side-chat.ts:130-171` + `websocket.ts:2417-2422` — ephemeral registry 无归属（owner）概念，任何客户端可关闭他人的 child

- **对比**：legacy `SideChatFeatureHandler` 用 `recordsByClient` 严格按 client 隔离（`side-chat.ts:128, 764-768`）；ephemeral 版的 `close_ephemeral_side_chat` **不校验发起方是否是创建者**，`broadcastEphemeralSideChatRegistry()` 也把全量 registry 广播给所有客户端。
- **后果**：多设备/多客户端时（iPhone + iPad + Web 预览），一端关闭面板会连带影响另一端；也让"谁的 child"无法追责。功能语义上是一致性缺口（安全面另有人覆盖）。
- **建议**：entry 增加 `ownerClientId`，close 时校验；广播按 owner 过滤或至少标注归属。

### [A-8] [P2] `apps/mobile/lib/models/local_features/slots/ephemeral_side_chat_protocol_slot.dart:104-114, 231-237` — 严格 key 白名单解析 + 上游错误吞没 = 新版 Bridge 一升级，侧聊天静默全失效

- **证据**：`_sideChatRequireOnlyKeys(json, const [...])` 是**只允许清单内 key**的严格校验。若新版 Bridge 给 entry 加一个字段，`FormatException` → `bridge_service.dart:1872-1877` 捕获后只发一条 `sessionId: null` 的通用 `Parse error` 气泡 → registry 消息被丢弃 → `refresh()` 的 15s Timer 超时 → `_reconcileCapability` 里的 `unawaited(refresh().catchError((_) {}))`（`ephemeral_side_chat_registry_service.dart:236`）**把错误完全吞掉**。
- **后果**：用户看到侧聊天列表永远为空 + 一条来路不明的 Parse error，无法归因。
- **建议**：解析改为"忽略未知 key"（向前兼容），并让 registry 超时把错误暴露到 UI 而不是 `catchError((_) {})`。

### [A-9] [P3] `apps/mobile/lib/main.dart:201-203, 392-394` — 外部构造的 registry 又交给 `ChangeNotifierProvider(create:)`，所有权重复

`ephemeralSideChatRegistry` 在 `main()` 里构造，又用 `create: (_) => ephemeralSideChatRegistry` 注入。Provider 移除时会 `dispose()` 一个它并不拥有的对象。当前是 app-root 级，风险低，但 hot restart / 测试环境下会出现"已 dispose 的 registry 被继续使用"。建议改用 `ChangeNotifierProvider.value`。

### [A-10] [P3] `apps/mobile/.../side_chat_controller.dart:665-668` — 死分支

`_onConnectionState` 里 `if (_disposed) { if (state != connected) _finishDisposeCleanup(); return; }` 永不可达：`dispose()` 第 731 行已经先 `_connectionSubscription?.cancel()` 再置 `_disposed = true`。清理完全依赖第 755 行的 12s Timer 兜底。逻辑上无害，属误导性死代码。

---

## B. 子 Agent

### [B-1] [P1] `packages/bridge/src/local-features/subagents.ts:834-838` + `apps/mobile/lib/models/local_features/slots/subagents_models_slot.dart:71-77` — `activeStatus` 判定用硬编码字符串白名单，且协议里的 `activeFlags` **传了但从没人用**

- **证据**：Bridge 侧把官方状态归一为
  ```ts
  status: stringOrNull(record.status) ?? stringOrNull(status.type) ?? "unknown",
  activeFlags: Array.isArray(status.activeFlags) ? ... : [],
  ```
  Mobile 侧：
  ```dart
  bool get isActive => const {'active','running','pending','starting','working'}
      .contains(status.toLowerCase());
  ```
  全仓库 grep `activeFlags` 仅命中 `subagents.ts:834` 与 `slots/subagents-protocol.ts:18` — **Dart 侧一处都没有**。
- **后果**：官方返回结构化状态（`{type:"idle", activeFlags:["turn"]}`）时，实际在跑的子 Agent 被判为 Done；返回未知 type 时一律落到 `"unknown"` → Done。悬浮小窗要"承载运行中的子 Agent"，而运行中的判定本身就不可靠。
- **建议**：`isActive` 改为 `activeFlags.isNotEmpty || 白名单命中`，并在 Dart 模型里解析 `activeFlags`。

### [B-2] [P1] `apps/mobile/lib/features/subagents/state/subagents_controller.dart:62-98` + `widgets/subagents_panel.dart:55-60` — 子 Agent 状态是**一次性快照**，没有推送、没有轮询，运行中→完成的收束根本不会发生

- **证据**：`subagents.ts` 全文无 `sessionMessage` / `broadcast` / watcher，是纯 request-response；`SubagentsController` 只在三处触发 `refresh()`：构造后 postFrame（且仅当 `subagents.isEmpty`）、`didUpdateWidget` 换 session、连接恢复。**没有 Timer 轮询**。
- **后果**：面板打开后不动，Active 列表里的子 Agent 完成/失败/被取消都不会更新；用户必须手动点刷新。悬浮小窗如果依赖同一数据源，"运行中"角标同样是冻结的。
- **建议**：Active 非空时启动 5-10s 轮询（并在 App 进入后台时暂停）；或让 Bridge 在 `thread` 状态变更时推送增量。

### [B-3] [P2] `subagents_controller.dart:28, 82-89` vs `subagents.ts:32-33` — Mobile 超时 12s 与 Bridge deadline 12-15s 完全撞车，慢响应必然被误报为 `unsupported`

- **证据**：Bridge `DEFAULT_SUBAGENT_DEADLINE_MS = 12_000` / `MAX_SUBAGENT_DEADLINE_MS = 15_000`；Mobile `requestTimeout = const Duration(seconds: 12)`，超时后：
  ```dart
  _listRequestId = null; listLoading = false; listError = 'unsupported';
  ```
- **后果**：仓库线程多、`thread/read` 链路慢时，Bridge 在第 12.x 秒成功返回，但 Mobile 已经清掉 `_listRequestId` → `SubagentListMessage` 在 188-191 行被丢弃 → UI 卡在"Bridge 不支持子 Agent"这个**完全错误**的结论上。
- **建议**：Mobile 超时提到 ≥ 20-25s（> Bridge 最大 deadline + RTT），且超时错误码不要用 `unsupported`（应为 `timeout`）。

### [B-4] [P2] `subagents.ts:83-91, 151-153` — 并发闸门按 **WebSocket 客户端**而非按 session，跨会话面板互相打架

- **证据**：`private readonly activeClients = new WeakSet<object>();`，命中即返回 `"Another subagent request is already in progress"`。
- **触发场景**：同一手机开着两个 Codex 会话的子 Agent 面板（或面板 + 悬浮小窗同时拉取）→ 两个独立 `SubagentsController` 各自认为自己空闲（Mobile 的 `_hasInFlight` 是 per-controller），其中一个必然拿到该错误。该消息不含 `unsupported` 字样 → `_normalizedError`（`subagents_controller.dart:292-300`）原样透出**英文原文**给用户。
- **建议**：闸门改为按 `client + sessionId`；或改成排队而非拒绝。

### [B-5] [P2] 子 Agent 面板是**只读**的，没有取消/中断能力

`subagents_panel.dart` 类注释即 "Read-only Active/Done browser"，全文无 cancel/interrupt/stop 相关消息，`subagents.ts` 的 `messageTypes` 只有 `get_subagents` / `get_subagent_history`。任务要求的"取消的收束"目前**根本没有实现路径**。若产品需要在悬浮小窗里停掉跑飞的子 Agent，需要新增协议。

### [B-6] [P3] `subagents_controller.dart:70-73` + `subagents_panel.dart:145-147` — 刷新按钮的"静默无响应"

`refresh()` 在 `_hasInFlight` 时 `_pendingRefresh = true; return;`，**不 notifyListeners、不置 listLoading**；而按钮的禁用条件是 `_controller.listLoading`。因此在 history 请求在途时点刷新，按钮仍可点、无任何视觉反馈、看起来像坏了。

### [B-7] [P3] 与父会话的关联链路本身是稳的（确认无问题）

`readVerified`（`subagents.ts:203-246`）先 `listWithinDeadline` 再校验 `childThreadId` 确实在后代集合中，且拒绝 `childThreadId === parentThreadId`；`readForkLineage`（295-330）有 `MAX_FORK_LINEAGE_DEPTH = 16` + `seen` 环路防护；`ancestorThreadId` 不被支持时有本地过滤兜底（273-292）。资源上限 `MAX_THREAD_ENTRIES = 2000` / `MAX_SUBAGENT_HISTORY_MESSAGES = 400` / `MAX_SUBAGENT_HISTORY_BYTES = 512KB` 都到位。这块写得好。

---

## C. 是否复用既有会话 UI

### [C-1] ✅ **官方 ephemeral 侧聊天确实复用了原生会话 UI —— 要求已满足**

`ephemeral_side_chat_pane.dart:191-203`：
```dart
return CodexSessionScreen(
  key: ValueKey('ephemeral_side_chat_${entry.childSessionId}'),
  sessionId: entry.childSessionId,
  projectPath: entry.projectPath, worktreePath: entry.worktreePath, ...
  allowMessageFork: false,
);
```
`CodexSessionScreen` 甚至专门为此加了 `allowMessageFork` 开关（`codex_session_screen.dart` 类注释明确写 "Auxiliary child conversations reuse the full Codex screen"）。**只改数据源和容器**这一条做到了。`persisted_side_chat_pane.dart:178-190` 同样复用（虽然整条链路是死代码）。

### [C-2] [P2] 但仓库里仍并存**两套自造聊天渲染**，且都有活的进入路径

1. **`side_chat/widgets/side_chat_panel.dart`（553 行）** + `side_chat/state/side_chat_controller.dart`（762 行）+ Bridge `local-features/side-chat.ts`（1241 行）：完整的一套自造气泡渲染（`SideChatEntry{id, role, text}`、自己的 ListView + flutter_markdown + 自己的权限/提问 UI）。它并非孤立死代码——`ephemeral_side_chat_pane.dart:173-184` 和 `persisted_side_chat_pane.dart:163-174` 都会在 `_useLegacyFallback` 时渲染它，而 [A-5] 说明这个 fallback 会被能力协商竞态误触发。
   - 有意思的是它**也**用官方 ephemeral fork（`side-chat.ts:1101` `ephemeralForkFromThreadId: parentThreadId`），所以问题纯粹是 UI 层重复造轮子，不是生命周期违规。
2. **`subagents/widgets/subagents_panel.dart:352-410`（`_TranscriptMessage`）**：把 `UserInputMessage / AssistantServerMessage / ToolResultMessage / ResultMessage / ErrorMessage` 全部降级成 `Text(label) + SelectableText(text)`，`ToolUseContent` 用 `_assistantContentText` 拍成 JSON 字符串。**完全没有复用** `widgets/bubbles/` 下的既有气泡组件（对比 `side_chat_panel.dart` 还知道复用 `ask_user_question_widget.dart`）。子 Agent 历史因此没有 markdown、没有 diff 高亮、没有工具折叠。
- **建议**：(1) 修好 [A-5] 后把 legacy `SideChatPanel` 整体删除（连同 `side-chat.ts` 的旧协议）；(2) 子 Agent 详情页改用现有的 `ChatMessageList` / bubbles，只换数据源。

### [C-3] [P2] `codex_session_screen.dart:1907-1925` + `ephemeral_side_chat_pane.dart:191-203` — 复用会话屏幕时没关掉悬浮小窗，导致**嵌套小窗**

- **证据**：公开的 `CodexSessionScreen` 构造函数**没有 `detachedPreview` 参数**（该参数只存在于内部的 `_CodexProviders`/`_CodexChatBody`，默认 `false`）。而悬浮小窗的渲染条件是 `if (!detachedPreview && ephemeralSideChatRegistry != null)`。
- **后果**：侧聊天面板里的那个 `CodexSessionScreen` 会**再渲染一层 `AuxiliaryFloatingDock`**（`sessionId` = child id）盖在上面。从这层小窗尝试新建侧聊天时，Bridge 会因 `websocket.ts:2299` 的 `parent.auxiliary` 守卫拒绝，返回文案是 `"The parent Codex session is no longer active"` —— 与真实原因（不允许嵌套 fork）完全不符。
- **建议**：给 `CodexSessionScreen` 暴露一个 `hideAuxiliaryDock`（或直接复用 `detachedPreview`），auxiliary 场景下传 true；Bridge 侧对 auxiliary 父会话返回专用错误码 `nested_side_chat_unsupported`。

---

## D. Git 功能正确性（Mobile + Bridge）

### [D-1] [P0] `packages/bridge/src/git-operations.ts:204, 222, 723` ↔ `apps/mobile/lib/features/git/widgets/diff_content_list.dart:172-176` — hunk 下标在客户端(U3)与服务端(U0)之间不一致，会 **stage / revert 错误的代码块**

- 客户端展示的 diff 来自 `gitArgs("diff", "--no-color")`（`websocket.ts:11686`，默认 3 行上下文），`hunkIdx` 就是这个 U3 解析结果的下标（`git_view_cubit.dart:381-425` 发 `{'file':..., 'hunkIndex': hunkIdx}`）；Bridge 收到后重新跑 `git diff --unified=0` 并按 `@@` 出现顺序取第 idx 段（`buildHunkPatch:107-111`）。
- **触发**：同文件两处改动相距 ≤6 行时，U3 合成 1 个 hunk、U0 拆成 2 个 → UI 上的第 2 个 hunk 对应服务端完全不同的内容 → **回滚掉用户没选的代码**（不可撤销的改动丢失）。
- 现有测试 `git-operations.test.ts:268-292` 特意选了第 2 行与第 17 行（相距 15 行），U3/U0 都是 2 个 hunk，恰好掩盖了这个 bug。
- **建议**：协议改传客户端重建的 patch 文本（`reconstructDiff` 已有），或两端统一 diff 参数，或在 `hunkIndex` 之外附带 `hunkHeader` 做校验，不匹配即拒绝。

### [D-2] [P0] `apps/mobile/lib/features/git/state/git_view_cubit.dart:57-73, 95-113` + `state/git_view_cache_service.dart:38-53` — git 结果流是全局广播且不带 `projectPath`/`requestId`，多会话缓存 Cubit 互相串台

- `DiffResultMessage`（`models/messages.dart:3474-3485`）与服务端 `{type:"diff_result", diff, imageChanges}`（`websocket.ts:8197`）**都不带 projectPath / sessionId / requestId**；而 `GitViewCacheService` 每个 session 常驻一个 Cubit，各自 listen 同一个全局流。
- **触发**：先后打开 session A、B 的 Git 面板 → A 的 `diff_result` 也被 B 消费 → B 的 `state.files` 变成 A 仓库的文件；此后在 B 上滑动 stage/revert，会把 **A 的文件路径**发到 **B 的 projectPath**。
- **建议**：所有 `git_*_result` / `diff_result` 回带 `projectPath` 或客户端 `requestId`，Cubit 侧过滤。

### [D-3] [P1] `packages/bridge/src/websocket.ts:8170-8173`（及 8307/8326/8344/8420/8485/8503/8521/8539/8557）— 路径不允许时只回 `type:"error"`，客户端 loading/staging 永久卡死

`buildPathNotAllowedError`（1605-1613）返回的是 `{type:"error", errorCode:"path_not_allowed"}`，**不是** `diff_result` / `git_stage_result`。客户端 `git_view_cubit.dart:136` 置 `loading: true` 后只等 `diffResults`，无超时、无 error 通道兜底 → 永久转圈；更糟的是 `git_screen.dart:327` 的 `if (cubit.canRefresh && !state.loading)` 会**隐藏刷新按钮**，用户无法自救。stage 失败同理让 `staging=true` 永久为真，`_isBusy`（`git_screen.dart:1039`）禁用全部按钮。

### [D-4] [P1] `apps/mobile/lib/features/git/widgets/branch_selector_sheet.dart:191-196` — checkout 失败被完全吞掉

```dart
onTap: isDisabled ? null : () { cubit.checkout(branch); Navigator.of(context).pop(); }
```
弹窗立刻 pop → `BranchCubit` 随 Provider close，`_onCheckoutResult` 的 `emit(error:)` 落到已销毁 cubit；而 `GitViewCubit._onCheckoutResult`（610-623）**只处理 success，失败分支为空**。工作区有未提交改动导致 checkout 失败时，分支没切、界面还是旧分支、**零提示**。

### [D-5] [P1] `apps/mobile/lib/features/git/state/git_view_cubit.dart:86, 107` — 全量 diff 在 UI 线程同步解析，无 isolate / 无截断 / 无分页

`parseDiff(result.diff)` 直接同步调用，全仓库无 `compute(` / `Isolate.run`。服务端 `maxBuffer: 10 * 1024 * 1024`（`websocket.ts:11627`）→ 最大可下发 10MB diff → 主线程阻塞数秒；超过 10MB 直接 `ENOBUFS`，用户只看到 `maxBuffer length exceeded`，**没有任何"diff 过大已截断"的降级路径**。

### [D-6] [P1] `apps/mobile/lib/features/git/widgets/diff_hunk_widget.dart:111, 118-131, 254-329` — 每行一次 `TextPainter.layout` + hunk 内零虚拟化 + 每次刷新全量重算

`_calcMaxContentWidth()` 在 `initState` 同步遍历全部行做 layout；`_DiffHunkBody.build` 用 `Column(children: [for (final line in lines) ...])`，外层虽是 `ListView.builder` 但**一个 item = 一整个文件的全部 hunk 全部行**。叠加：`if (oldWidget.hunk != widget.hunk)` 中 `DiffHunk` 没重写 `==`（`diff_parser.dart:95-118`），每次 stage/unstage 后的刷新都会对所有可见 hunk 触发全量 TextPainter 重算。

### [D-7] [P1] `apps/mobile/lib/features/git/widgets/diff_image_widget.dart:384` + `services/bridge_service.dart:351, 5052-5058` — 图片全分辨率解码 + 无上限内存缓存

`Image.memory(bytes, fit: BoxFit.contain)` 无 `cacheWidth/cacheHeight`，容器只有 `maxHeight: 200` 却按原始分辨率解码；服务端允许 5MB（一张 8000×8000 PNG ≈ 解码后 256MB ARGB，old/new 各一份）。`_diffImageCache` 是裸 Map，无容量/字节上限、无 LRU，只在 session 停止或断线才清。

### [D-8] [P2] `websocket.ts:11669-11696` — `git add --intent-to-add` 与 `git reset` 之间夹着**异步** `git diff`，并发操作会误撤销用户暂存

unstaged 模式先同步 `git add --intent-to-add -- <untracked...>`，然后**异步** `execFile("git", ["diff"...])`，在回调里才 `execFileSync("git", ["reset", "--", ...untrackedFiles])`。diff 在途时用户点 "Stage All" → 回调到来后 `git reset` 把刚 stage 的新文件又撤了。**整个 Bridge 没有任何 git 串行化**（`git-operations.ts` 全用 `execFileSync` 靠阻塞事件循环"意外"串行），唯独 diff 路径是异步的，形成这个空窗。

### [D-9] [P2] `git_view_cubit.dart:240-242` + `diff_image_widget.dart:45-56` — 图片自动加载被限流拒绝后永久转圈

`if (state.loadingImageIndices.length >= _maxConcurrentLoads) return;` 静默丢弃；`_triggerAutoLoad` 只在 build 触发一次，被丢弃后 state 不变 → widget 不重建 → 永远停在 spinner。配合 [D-3]（`diff_image_result` 永不到达）三个槽位占满后**所有**图片都加载不出来。

### [D-10] [P2] `git_view_cubit.dart:344-353` — 快速切换 staged/unstaged 响应乱序

`switchMode` 立刻 emit 新 mode 并发 `get_diff`，`diff_result` 无 mode 标记 → 先到先赋值后到覆盖 → `viewMode = unstaged` 但 `files` 是 staged 内容，此时滑动做的 stage 操作实际针对已暂存文件。

### [D-11] [P2] `apps/mobile/lib/utils/diff_parser.dart:164, 237, 325` — 不支持 combined diff（`@@@`）

`lines[i].startsWith('@@')` 会把 `@@@ -1,5 -1,5 +1,7 @@@` 当成 hunk 头，但 `_hunkHeaderRegex` 不匹配 → 落到 `oldStart=1, newStart=1` 的 fallback（313-314），**行号全错**；combined diff 的两字符前缀（`++`/`+ `/` -`）也被按单字符解析。merge/rebase 冲突期间的 diff 全废。

### [D-12] [P2] `diff_parser.dart:361-364` — 空行被无条件跳过，其后所有行号偏移

```dart
} else if (line.isEmpty) { i++; continue; }   // 意图是吃掉末尾空元素
```
对 hunk **内部**的空行同样生效（行尾空格被去掉的上下文空行很常见）→ 既不计入 `diffLines` 也不递增 `oldLine/newLine` → 该 hunk 后续所有行号少 1，且屏幕上少一行上下文。应改为"仅当已是最后一个元素且为空串"时跳过。

### [D-13] [P2] `git_screen.dart:819-821` + `git_view_cubit.dart:483/492/501/517/526/573/590` — 任何操作失败都用全屏错误页顶掉整个 diff 列表

`if (state.error != null) return DiffErrorState(...)`，而 stage/unstage/revert/pull/push 失败共用同一个 `error` 字段。一次 stage 失败 → 整页 diff 消失，且无自动清除路径。

### [D-14] [P2] `git-operations.ts:739-746, 881-895` — 同步 `execFileSync` 阻塞整个 Bridge 事件循环

`gitFetch` 的 `execFileSync(..., {timeout: 30000})` 最长把 Node 主线程钉死 30 秒；`gitPull` 的 `execFileSync("git", ["pull"])` **没有 timeout**，凭证交互/网络挂起时可无限阻塞——期间所有 WebSocket 会话（含正在跑的 Claude/Codex）全部停摆。注意 `gitStatus` 在 `includeRemote` 时会内部再调 `gitFetch`（828），而 `GitStatusCubit.refresh` 被会话列表频繁触发。

### [D-15] [P2] `websocket.ts:11873-11904, 8194` — 仅为取尺寸就把整张图读进内存；`collectImageChanges` 无 `.catch`

`oldBuf = result.stdout`（整个 blob）+ `newBuf = await readFile(absPath)`（**无 size 检查**，`MAX_IMAGE_SIZE` 校验在读之后 11904-11909），只为算 `.length`。一个 200MB 的 `.bmp` 直接读满内存。另外 `void this.collectImageChanges(...).then(...)`（8194）**没有 `.catch`** → reject 时客户端永远收不到 `diff_result`（配合 [D-3] 变成永久 loading），Node 侧还是 unhandled rejection。

### [D-16] [P3] `diff_parser.dart:199-254` — 重命名 / 模式变更未识别，渲染成"空文件"

元数据循环只认 `Binary files` / `new file mode` / `deleted file mode`，没有 `rename from|to`、`similarity index`、`old mode|new mode`、`copy from|to`。纯重命名/纯 chmod 得到 `hunks: []` → `diff_content_list.dart:143` 渲染出一个 `+0 -0`、下面完全空白的区块；`_extractFilePath` 只取新路径（681-693），旧路径丢失。

### [D-17] [P3] `diff_parser.dart:177` + `websocket.ts:11684-11687` — CRLF 与非 UTF-8 编码

- CRLF：`split('\n')` 后每行残留 `\r`，进 `DiffLine.content` → 宽度多算一字符；`reconstructUnifiedDiff` 用 `writeln`（`\n`）回写，产出的 patch 行尾与原文件不一致。
- 非 UTF-8：`collectGitDiff` 未指定 encoding（默认 utf8）、`getStagedDiff` 显式 `encoding:"utf-8"` → Shift_JIS/GBK 文件的 diff 变成 U+FFFD，不可逆；这样的内容再通过 "Request Change" 回传给 AI 就是乱码。
- **路径侧是好的**（确认无问题）：`withGitPathConfig` 统一加 `-c core.quotePath=false`（`git-operations.ts:87-89`），客户端 `_decodeGitPathToken`（738-796）还实现了八进制反转义兜底，CJK 路径有测试覆盖（`test/diff_parser_test.dart:177-240`）。

### [D-18] [P3] `git_view_cache_service.dart:28-53` — 缓存只按 sessionId 索引，路径变了仍返回旧 Cubit

`getOrCreate` 第一件事就是按 `sessionId` 命中返回，**完全忽略传入的 projectPath / worktreePath**；而调用方 `git_screen.dart:175` 的 key 是 `'$sessionId\n$projectPath\n${worktreePath ?? ''}'` → key 变了会重新 `getOrCreate`，却拿回持有旧 `_projectPath`（final）的 Cubit。会话后来切到 worktree 时，Git 面板仍对旧路径发 `get_diff`/`git_stage`。

### [D-19] [P3] `diff_parser.dart:357-360, 536-545, 652-662` — `\ No newline at end of file` 被丢弃，重建 patch 凭空加换行

解析时 `else if (line.startsWith(r'\')) { i++; continue; }` 直接丢标记，`DiffHunk` 无字段记录；`reconstructDiff`/`reconstructUnifiedDiff` 对每行都 `writeln`。对无末尾换行的文件做 "Request Change"，回传给 AI 的 diff 语义已变；若将来用于 `git apply` 会直接失败。

### [D-20] [P3] `git-operations.ts:700-703` + `diff_parser.dart:688-692` — 路径解析边界不一致 / 含换行的文件名

- `revertFiles` 用 `git(["ls-files", "--", ...files])` 后 `split("\n")`：文件名含换行会被拆成两条 → 判为 untracked → 走 `git clean -fd` **删文件**。应用 `ls-files -z` + `\0` 切分。
- 客户端 `_extractFilePath` 用 `lastIndexOf(' b/')`，Bridge 图片扫描用 `/^diff --git a\/(.+?) b\/(.+)$/`（`websocket.ts:11835`，取**第一个** ` b/`）。对形如 `x b/y.png` 的文件名两端解析不同 → `_mergeImageChanges` 的 `imageMap[file.filePath]` 匹配不上，图片 diff 静默退化为 "Binary file"。

**Git 侧确认无问题的点**：`GitViewCubit.close()` / `BranchCubit.close()` / `CommitCubit.close()` / `GitStatusCubit.close()` / `GitViewCacheService.dispose()` 都取消了订阅；`_GitScreenState.dispose` 正确 remove listener + dispose controller；`DiffImageViewer` 的 `AnimationController`/`TransformationController` 均已 dispose；`diff_image_widget.dart:50-55` 与 `git_screen.dart:123-126, 259-261` 的 post-frame 回调都有 `mounted` 保护；二进制识别、`git_file_list_sheet` 树构建、`branch_selector_sheet` 的 `checkedOutBranches` 禁用逻辑功能上无问题。

---

## E. 常规 bug（订阅/Timer/竞态/错误吞没）

> 本组同时覆盖审查范围 1 中的 `session_archive` / `session_insights` / `session_link` / `explore`。

### E-a. session_link

**[E-1] [P1] `session_link/state/session_link_cubit.dart:36-42` + `session_link_screen.dart:31`** — `resolve()` 无 try/catch，抛异常即永久卡在 "Resolving…"。调用方是 `SessionLinkCubit(...)..resolve()` 的 fire-and-forget，而 `bridge_service.dart:3204-3209` 的 `connectionStatus.firstWhere(...)` **无 `orElse`**、`on TimeoutException` **只 catch 超时**：controller 被 close（`bridge_service.dart:5098`）时抛的 `StateError` 会穿透；`finally` 里的 `jsonDecode(...)`（3237）也会抛并覆盖返回值。一旦抛出，state 永停在 `resolving`，而 `SessionLinkStatusView`（screen:150-171）只在 `unavailable` 时才显示"打开最近会话"逃生按钮 → **死转圈无出口**。

**[E-2] [P1] `session_link_cubit.dart:83-116`** — resume 阶段完全没有超时/断线兜底。`resolve()` 侧有 10s 超时，`_resume` 一个都没有，只能等 `session_created` / `session_resume_failed`。Bridge 崩溃或旧版不回失败消息时永停在 `resuming`，同样无逃生按钮。

**[E-3] [P3] `session_link_cubit.dart:85-92, 99-110`** — `_resumeGitBranch = dispatch.gitBranch` 赋值在 `await _resumeCoordinator.resume(...)` **之后**，而订阅在之前建立。若 `session_created` 先到，`_handleResumeMessage` 会用 `gitBranch: null` 构造 `openResumed`，路由跳转丢分支名（screen:64-77 的 `session.worktreeBranch ?? gitBranch`）。应在建立订阅前从 `RecentSession` 取值。

### E-b. explore

**[E-4] [P1] `explore/state/explore_cubit.dart:22-28` + `explore_screen.dart:246-251`** — 无限 loading：初始 `@Default(ExploreStatus.loading)`，构造函数里 `_bridge.requestFileList(projectPath)` 是纯 fire-and-forget（无 requestId、无 Timer），`_applyFiles` 只 emit `ready`/`empty` 且恒 `error: null`。全局确认 `ExploreStatus.error` / `ExploreState.error` **在 lib/ 下没有任何一处被赋值**，`explore_screen.dart:250` 的 error 分支是死代码。

**[E-5] [P1] `explore/state/explore_cubit.dart:23, 30-36`** — 对 `FileListMessage` 零关联，任何一路响应都覆盖当前目录树。`FileListMessage`（`models/messages.dart:3384-3394`）**没有 projectPath / requestId**；`bridge_service.dart:1672-1674` 对所有订阅者广播，2045 行在会话重置时主动推**空**列表 → Explorer 直接翻到 "No files to explore" 且永不恢复。加剧因素：`codex_session_screen.dart:1102-1111` 的 app-resume 回调**没有 `isBackground` 守卫**（同文件 1023 行的挂载逻辑是有的），每个常驻会话恢复时都会用自己的 `chatFileRoot`（worktree 会话下 ≠ Explorer 的 projectPath）重新请求；`claude_session_screen.dart:897` 同款。

**[E-6] [P2] `explore_screen.dart:140-151, 157`** — `_ensureHighlightedVisible()` 在 `build()` 内注册 post-frame 回调，且用的是**上一帧的 context**且未校验 `.mounted`。`_highlightedFilePath` 在 peek 后从不清空 → 只要高亮着，之后每次 BlocBuilder 重建都再排一次 220ms 滚动动画（表现为列表被反复"拽"回去）；若该 tile 已因切目录被移除，`Scrollable.ensureVisible` 对 deactivated element 会抛异常。

**[E-7] [P2] `explore_cubit.dart:14-28`** — 无 `connectionStatus` 订阅，断线重连后 Explorer 不会自动恢复（配合 [E-5] 的空列表重置，会一直停在空状态）。

**[E-8] [P3] `explore_cubit.dart:108-112`** — `close()` 未 await `_fileListSub.cancel()`（对比 `session_archive_cubit.dart:309-315` 是 await 的），且 `_applyFiles`/`openDirectory`/`goUp` 的 emit 均无 `isClosed` 守卫。broadcast stream 下实际风险低，但属"Cannot emit after close"的典型埋雷形态。

**[E-9] [P3] `explore_cubit.dart:167-177`** — `normalizeExplorePath` 静默逐层上跳直至回根，用户不知道自己被弹回了哪一层；且是 O(depth × n) 线性扫描。另外 `buildExploreEntries`（115-159）只从**文件路径**反推目录，所以真正的空目录 / 只含被过滤文件的目录 / 符号链接目录在 Explorer 中**不可表达**。

### E-c. session_archive

**[E-10] [P1] `session_archive/session_archive_cubit.dart:83-87, 283-301`** — 把"连接抖动"当作"操作失败"上报，与同 feature 既有纪律自相矛盾（删除是破坏性操作）。订阅对**任何非 connected 状态**（含每次重连开头的 `connecting`/`reconnecting`，见 `bridge_service.dart:1424, 2287, 2293`）都触发 `_failAll` → `_failRequest` 写成 `error:` → UI 渲染 `strings.failed(...)`。而 `session_archive_pending_requests.dart:30-33` 的注释明确写着相反策略："A timeout or disconnect only releases local busy state and **reports that the result is unknown**"，对应文案 `archiveResultUnknown` 已存在但这条路径没用。**后果**：Bridge 已删除成功，用户看到"操作失败"，列表也不刷新，被删的会话还在。

**[E-11] [P2] `session_archive_cubit.dart:152-154` + `session_archive_screen.dart:200-204, 215-218`** — `_mutate` 在去重命中时静默返回 `false` 且不 emit error，屏幕侧却把所有 `false` 一律当失败并拼接**可能属于上一次无关操作**的 `state.error`：`Text(success ? strings.restored : strings.failed(cubit.state.error ?? ''))`。结果是弹"操作失败："（空 detail），或弹一条与本次操作无关的旧错误。

**[E-12] [P2] `session_archive_cubit.dart:83-87` + `session_archive_screen.dart:76-104`** — 连接恢复分支什么都不做（只有 `if (status != connected)`），重连后列表保持陈旧；且归档屏幕用裸 `ListView(children: [...])` 一次性构建全部 tile，千级列表全部同时实例化，无 builder 复用，截断提示（`strings.truncated`）也没有"加载更多"入口。

**[E-13] [P3] `session_archive_cubit.dart:98-99`** — `if (!state.supported || state.isLoading) return false;` 与 `RefreshIndicator(onRefresh: () => cubit.refresh())` 语义不匹配：已有请求在途时立刻拿到完成的 Future → 指示器瞬间收起，用户以为刷新完成。应返回在途请求的 future。

### E-d. session_insights

**[E-14] [P2] `session_insights/widgets/session_insights_bar.dart:315-342`** — `_SessionInsightsPanelState` **完全没有 `didUpdateWidget`**（对比 `_SessionInsightsBarState` 52-61 是正确的）。Flutter 复用同一 State 时，切换会话后 panel 仍绑定旧 `sessionId` 的 controller，显示错误会话的 context/quota，旧 controller 订阅泄漏到新会话生命周期。

**[E-15] [P2] `session_insights_bar.dart:75-78, 226-251`** — 底部详情 sheet 是独立 route 但持有同一个 controller 实例；`_removeController()` 在 dispose 时无条件 `_controller.dispose()`。sheet 打开期间底层 bar 被移除（切会话/工作区重排）→ `ListenableBuilder` 对已 dispose 的 `ChangeNotifier` 操作命中 `_debugAssertNotDisposed`。

**[E-16] [P3] `session_insights/state/session_insights_controller.dart:148-212, 234-243`** — `_onSessionMessage` 的四个分支都直接 `notifyListeners()`，**缺 `_disposed` 守卫**（同类里 `_minuteTimer` 83-85 和 `_clearLoading` 231 都做了，明显遗漏），且 `dispose()` 里 `_sessionSubscription?.cancel()` 未 await。

### E-e. side_chat / subagents 侧的常规 bug

**[E-17] [P2] `side_chat/widgets/persisted_side_chat_pane.dart:80-82, 99-101`** — `initState → _listenAndOpen() → _open()` 路径上调用 `SideChatStrings.of(context)`，而它内部是 `Localizations.localeOf(context)` = `dependOnInheritedWidgetOfExactType`，**在 initState 中调用会抛 FlutterError**。触发条件：面板在 Bridge 断线时打开。同文件 74 行还在 initState 中 `setState`。（缓解：该 pane 当前无引用方，见 [A-6]，属死代码——但如果按建议保留，必须修。）

**[E-18] [P2] `side_chat/state/ephemeral_side_chat_registry_service.dart:236`** — `unawaited(refresh().catchError((_) {}))` 是纯粹的错误吞没，registry 刷新失败（超时、解析失败、Bridge 报错）时用户界面上没有任何痕迹。配合 [A-8] 会导致"侧聊天列表永远为空且无法归因"。

**[E-19] [P3] `subagents/state/subagents_controller.dart:82-89, 133-141`** — 超时统一映射为 `listError = 'unsupported'` / `historyErrors[x] = 'unsupported'`，把"慢"误报为"Bridge 不支持"（详见 [B-3]）。`_normalizedError`（292-300）还会把任何含 `unsupported` 字样的服务端消息一并折叠，掩盖真实原因。

**已确认无问题的生命周期点**：`EphemeralSideChatRegistryService.dispose()`（344-353）取消了全部 4 个订阅并 fail 掉所有 pending；`SideChatController.dispose()` 的延迟清理（751-759 + 716-721）逻辑正确；`SubagentsController.dispose()`（278-289）取消了两个订阅与全部 Timer；`session_archive_pending_requests.dart` 的双重去重（56-81）、"唯一候选才认领"（85-107）、`_takeAll` 统一取消 Timer（140-147）设计严谨；`SessionInsightsController` 的 `_contextGeneration`/`_quotaGeneration` + `_quotaRequestId` 双重竞态守卫是本次审查范围内做得最好的一处。

---

## 优先级建议（如果只能先修 5 条）

1. **[D-1]** hunk 下标 U3/U0 不一致 —— 唯一会造成**用户代码丢失**的问题。
2. **[A-1]/[A-2]** ephemeral child 僵尸不回收 —— 直接推翻"registry 反映真实存活状态"这一验收前提，"重开"状态项无法关闭。
3. **[A-3]** 主入口不复用存活 child —— 产品语义错误 + 4 次就撞上限。
4. **[D-2]** git 结果流串台 —— 跨会话误操作。
5. **[B-1]/[B-2]** 子 Agent 运行中判定不可靠 + 状态永不更新 —— 悬浮小窗"承载运行中子 Agent"这条产品要求当前不成立。
These notifications are just the wait timers I set while the parallel reviews ran — no new findings. The review is already complete and delivered. Let me cancel the remaining idle timers so they stop generating noise.
这些通知只是我为等待并行审查而设的空转计时器完成，不含任何新发现。审查已完成并已在上一条消息中完整交付，剩余的空闲计时器已全部取消。

审查结果回顾（无文件被修改，全程只读）：

- **A. Side Chat 生命周期**：官方 `thread/fork(ephemeral:true)` 确实在用（`codex-process.ts:2698-2705`，还有三重返回值契约校验）；全域搜索**无任何 30 分钟/1800/TTL 硬编码**。但 registry 与真实存活状态**完全没有对账**——child 进程退出后会话永不销毁且被排除在空闲回收之外（P0），僵尸永久占用 8/4 配额（P1）；更关键的是关闭面板后从菜单重开会**再 fork 一个新 child** 而非找回存活的那个（P1），"重开"这一状态项因此无法关闭。
- **B. 子 Agent**：运行中判定依赖硬编码字符串白名单，协议里的 `activeFlags` 传了但 Dart 侧一处都没解析（P1）；状态是一次性快照，无推送无轮询，完成/失败根本不会收束（P1）；取消能力完全未实现。
- **C. UI 复用**：ephemeral 侧聊天**确实复用了 `CodexSessionScreen`**，要求已满足；但仓库里仍并存两套自造聊天渲染（legacy `SideChatPanel` 有活的误触发路径，子 Agent 详情页则完全没复用既有气泡）。
- **D. Git**：最严重的是 hunk 下标在客户端 U3 与服务端 U0 之间不一致，会 stage/revert 错误代码块（P0，且现有测试恰好绕开了它）；以及 git 结果流不带 projectPath 导致多会话缓存串台（P0）。
- **E**：涵盖 session_link 无限转圈、explore 被空列表广播重置、session_archive 把连接抖动误报为删除失败等。

如需我针对其中任何一条深入验证或给出具体修复方案，请告诉我优先项——按规则我不会在未确认前动任何文件。
