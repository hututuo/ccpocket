I'll start by reading the target file in chunks.
我已完整读完 6965 行（重点段落逐行读过），并交叉核对了 `codex-transport.ts`、`codex-agent-turn-tracker.ts`、`session.ts` 的监听器、以及全仓库无 `process.on('unhandledRejection')`（仅 `index.ts:479/482` 有 SIGINT/SIGTERM）。以下是**未被主审覆盖**的发现。

---

**[1] [P0] [codex-process.ts:2450 (approve 2193 / approveAlways 2214 / reject 2244 / answer 2264)]**
问题：审批解决后无条件 `setStatus("running")`，不检查是否还有活跃 turn，导致会话永久卡死无法再输入。
触发场景：turn/completed 先于审批被解决而到达（例如用户中断、guardian 审阅、多客户端并发）。`handleTurnCompleted` 因 `pendingApprovals.size > 0` 不置 idle（4350-4355），但已把 `pendingTurnId = null`（4327）。此后用户点批准 → 状态变 `running` 且永不再有 turn/completed 把它拉回 idle。
证据：
```ts
// 2446-2451
if (this._idleWhenInteractionsClear) { ...; this.setStatus("idle"); }
else { this.setStatus("running"); }   // ← 无 pendingTurnId 判断
```
对比 `handleServerRequestResolved` 里的正确写法 `this.setStatus(this.pendingTurnId ? "running" : "idle")`（5010）——同一语义两处实现不一致，证明这是遗漏。
后果链：`isWaitingForInput` 要求 `_status !== "running"`（631-637），于是 `sendInput/sendInputStructured` 全部走 “No pending input resolver” 分支直接 return（2042-2044），该 session 只能重启。
建议：`resumeRunningIfNoPendingInteractiveRequest` 末尾改为 `this.setStatus(this.pendingTurnId || this.activeCoreActionTurnId ? "running" : "idle")`。

**[2] [P0] [codex-process.ts:1961-1969]**
问题：`transport.on("error")` 不调用 `rejectAllPending()`、不置 `this.transport = null`、不 `stop()`；而 stdio transport 只监听 `exit` 不监听 `close`。spawn 失败（ENOENT，即 Codex CLI 未安装）时 Node 只发 `error` + `close`，**不发 `exit`**，于是 `bootstrap` 里无超时的 `await this.request("initialize")` 永久挂起。
证据：
```ts
transport.on("error", (err) => {
  if (this.stopped) return;
  ...
  this.emitMessage(codexAppServerStartError(err));  // 正是 CODEX_CLI_NOT_FOUND 路径
  this.setStatus("idle"); this.emit("exit", 1);     // 既不 rejectAllPending 也不清 transport
});
```
配合 `codex-transport.ts:71` `isRunning = child !== null && !child.killed`（ENOENT 后仍返回 true），后续 `writeEnvelope` 会向死 stdin 写入 → EPIPE。
建议：error 分支复用 exit 分支的清理（`rejectAllPending` + `transport.stop()` + `this.transport = null`），或 transport 改监听 `close`。

**[3] [P1] [codex-process.ts:4278 + 3518-3542]**
问题：`isForeignThreadNotification` 在 `this._threadId` 为空时**丢弃所有** thread/turn/item 通知；而 `_threadId` 是在 `thread/start` 的 RPC 响应 `await` 之后（2818）才赋值——`await` 续体是微任务，跑在 `handleStdoutChunk` 整个同步 while 循环之后。
触发场景：app-server 把 `thread/start` 响应和随后的 `turn/started` / `item/*` 写在同一个 stdout chunk 里（管道下极常见），这些通知在同步循环中被逐条处理，此时 `_threadId` 仍为 null → 全部静默丢弃。
证据：
```ts
// 4278
if (!this._threadId) return true;   // 丢弃
// 3520-3529：整个 while 循环同步执行 handleRpcEnvelope，resolve 只排微任务
```
后果：丢失 `turn/started` 会导致 `pendingTurnId` 永远为空，中断/steer 全部失效；resume 时回放的历史 item 丢失。
建议：在 `handleRpcEnvelope` 里同步识别 thread/start|resume|fork 的响应并立刻写入 `_threadId`，或对无法归属的通知做短暂缓冲重放。

**[4] [P1] [codex-process.ts:2471 / 2889-2891 / 943-949 / 1826]**
问题：多处 `void promise` 完全没有 catch，且这些 promise 的最后一步在 try 之外调用 `emitMessage`（同步 `emit`，session.ts:700 的监听器体内含大量非 try 保护逻辑）。本仓库无 `unhandledRejection` 处理器，Node 18 默认 `--unhandled-rejections=throw`，任一次抛出就**终止整个 Bridge 进程**（所有 Claude/Codex 会话一起死）。
证据：
```ts
// 2471  approveUserInput 内，唯一调用点，无 .catch
void this.installToolSuggestion(pending.toolUseId);
// 943-949  probeNextTurnPermissionUpdates：emitMessage 在 try/catch 之外
if (!this.stopped) { this.emitMessage({ type:"system", subtype:"runtime_capabilities", ...}); }
// 2889-2891  三个 void 调用全部无 catch
void this.probeNativePlanModeSupport(); void this.probeNextTurnPermissionUpdates(); void this.fetchCompletionEntities(projectPath);
```
`bootstrap`（1826 `void this.bootstrap(...)`）的 catch 块里同样连调两次 `emitMessage` + `setStatus` + `emit("exit")`，同一风险。
影响范围：全局（Bridge 进程级），不止本会话。
建议：所有 `void x()` 一律改为 `x().catch(logOnly)`；同时在 `index.ts` 注册 `process.on("unhandledRejection")` 兜底。

**[5] [P1] [codex-process.ts:1870-1934 + 553 + 3124-3128]**
问题：`prepareLaunch` 重置了 `_skills/_apps/_plugins/_lastCompletionEntitiesSignature/_launchStartedAt`，但**没有重置 `_completionFetchInFlight` 和 `_completionFetchCooldownUntil`**；同时 `_fetchCompletionEntitiesInternal` 只用 `this.stopped` 做守卫，而 `prepareLaunch` 又把 `stopped` 置回 false。
触发场景：start → completion fetch 在途 → stop() → 立即 start()（切换 project/权限重启是常见路径）。新一轮 `fetchCompletionEntities(newPath)` 命中 `if (this._completionFetchInFlight) return`，新 session 的 skills/apps **永远不会被拉取**；同时旧一轮的 `.then` 因为 `stopped` 已被重置回 false 而通过守卫，把**旧 projectPath 的 skills 写入新 session** 并 emit `supported_commands`。
证据：
```ts
// 3125-3129
if (this._completionFetchInFlight) return this._completionFetchInFlight;
this._completionFetchInFlight = this._fetchCompletionEntitiesInternal(projectPath);
// 3236 / 3269 / 3285 守卫只有：if (this.stopped || result === null) return;
```
建议：`prepareLaunch` 里清空 `_completionFetchInFlight`/`_completionFetchCooldownUntil`；内部守卫改用 `_runtimeGeneration` 快照比对（该字段已存在且在 prepareLaunch 自增）。

**[6] [P1] [codex-process.ts:3720 / 3749 / 3781 / 3812 / 3837]**
问题：`pendingApprovals.set()` / `pendingUserInputs.set()` 全部无重复键检查，同一 `toolUseId` 的第二次请求直接覆盖第一条，被覆盖的 `requestId` **永远收不到响应**，app-server 侧那条 JSON-RPC 请求永久阻塞该 turn。
触发场景：`extractToolUseId` 在无 `approvalId`/`elicitationId` 时回退到 `itemId`（4965-4974），同一 command item 先请求命令审批、再请求 `item/permissions/requestApproval`，两者共用 itemId 且都进 `pendingApprovals`。
证据：
```ts
this.pendingApprovals.set(toolUseId, { requestId: id, toolUseId, ... }); // 无 has() 检查
```
建议：set 前若已存在同键，先用 decline/cancel 响应旧 requestId 再覆盖，并 emit `permission_resolved`。

**[7] [P1] [codex-process.ts:4358-4361]**
问题：`handleTurnCompleted` 末尾**无条件** resolve `pendingTurnCompletion`，不校验 turnId 是否属于本次 Bridge 发起的 turn。
触发场景：Goal 续跑 turn / review 子 turn / Desktop 侧 turn 的 completed 通知（同一 threadId 因此通不过外部线程过滤）会提前 resolve 当前 `runInputLoop` 的等待，导致真正的 turn 仍在跑时循环已进入下一轮接受输入；同时对每个非本地 turn 都向客户端 emit 一条 `result` 消息（4295-4325），产生重复结果气泡。
证据：
```ts
if (this.pendingTurnCompletion) { this.pendingTurnCompletion.resolve(); this.pendingTurnCompletion = null; }
```
上方 4327 对 `pendingTurnId` 是有 turnId 守卫的（`if (!turnId || this.pendingTurnId === turnId)`），这里却没有。
建议：同样加 `if (!turnId || turnId === completedOwnTurnId)` 守卫。

**[8] [P1] [codex-process.ts:4776 + 3382]**
问题：`toRpcInput` 中 `await writeFile` 失败时，已写出的 `tempPaths` 是函数局部变量，不会返回给调用方，**临时图片文件永久泄漏在 tmpdir**；且调用点没有 try/catch，异常直接冒泡出 `runInputLoop` 的 while 循环，整个会话终止。
证据：
```ts
// 4772-4778
const tempPath = join(tmpdir(), `ccpocket-codex-image-${randomUUID()}.${ext}`);
await writeFile(tempPath, buffer);   // 抛出则前面已写的文件全部泄漏
tempPaths.push(tempPath);
// 3382 调用点：const { input, tempPaths } = await this.toRpcInput(pendingInput);  ← 无 try
```
建议：`toRpcInput` 内部 try/catch 自清理，或改为抛出携带 `tempPaths` 的错误；调用点包 try/catch 后 `continue` 而非中断循环。

**[9] [P1] [codex-process.ts:1971-1983 + 4411-4416]**
问题：`cleanupSteerTempPaths()` 只在 `handleTurnCompleted`(4362)、`stop()`(1858)、`prepareLaunch()`(1888) 被调用；transport 的 `exit` 处理器不调用它。app-server 异常退出且外部不再调用 `stop()` 时，steer 上传的图片临时文件永久残留。
证据：
```ts
transport.on("exit", (code) => {
  this.transport = null;
  this.rejectAllPending(new Error("codex app-server exited"));
  ...   // 没有 cleanupSteerTempPaths()
});
```
建议：exit/error 处理器统一调用 `cleanupSteerTempPaths()`。

**[10] [P2] [codex-process.ts:1075-1082]**
问题：`persistRuntimeThreadSettings` 的 promise 链与 `updatePermissionSettingsForNextTurn`（905-921）处理方式不对称——后者显式写了 `operation.then(()=>undefined, ()=>undefined)` 双分支，前者只有成功分支：
```ts
this._threadSettingsUpdateTail = operation.then(() => undefined);   // ← 无 onRejected
const pending = operation.then(() => undefined);
this._pendingRuntimeThreadSettingsUpdate = pending;
void pending.then(() => { ... });                                   // ← 无 onRejected
```
一旦 `operation` reject（今天靠内部 try/catch 恰好不会，但这是隐式契约）：(a) `void pending.then(...)` 产生未处理 rejection → Bridge 进程崩溃；(b) `_pendingRuntimeThreadSettingsUpdate` 永不清空，`waitForPendingThreadSettingsUpdates()` 每次都重新 await 同一个 rejected promise → `runInputLoop` 此后每条输入都命中 3391 的 `set_permission_mode_rejected` 分支被丢弃，**会话永久污染**。
建议：与权限路径保持一致，两个 `.then` 都补 onRejected。

**[11] [P2] [codex-process.ts:4423 / 4490]**
问题：item 无 `id` 时 started 与 completed 各自生成**不同**的 `randomUUID()`，导致 `startedToolItems` 匹配不上。
证据：
```ts
// 4423 processItemStarted
const itemId = typeof item.id === "string" ? item.id : randomUUID();
// 4490 processItemCompleted —— 同样一行，但 UUID 不同
```
后果：`ensureStartedToolUse` 找不到 started 记录 → 重复 emit 一条 `tool_use`（UI 出现两行工具卡片），且 started 那条的 `tool_result` 永远不会到达（toolUseId 不匹配），started 条目在 `startedToolItems` 中泄漏。
建议：无 id 的 item 直接 return 或用稳定回退键（如 `${turnId}:${itemType}:${index}`）。

**[12] [P2] [codex-process.ts:608 + 4439-4441]**
问题：`startedToolItems` 只在 `ensureStartedToolUse` 里 delete（4471）和 `prepareLaunch` 里 clear（1924）。turn 被中断/失败时已 started 未 completed 的 item 条目永久堆积，长会话内存单调增长（无容量上限，对比 `emittedGuardianReviewIdOrder` 有 256 上限、`expectedGoalNotifications` 有 64 上限，说明其它 Map 都做了限界）。
建议：在 `handleTurnCompleted` 里清理该 turn 的残留条目，或加 LRU 上限。

**[13] [P2] [codex-process.ts:3199-3209]**
问题：`requestOrNull` 用 `Promise.race` 做超时，**既不 clearTimeout 也不取消底层 RPC**。
证据：
```ts
Promise.race([
  this.request(method, params).catch(...),
  new Promise<null>((resolve) => setTimeout(() => resolve(null), TIMEOUT_MS)),
])
```
后果：(a) 每次 completion fetch 挂 3 个 10s 定时器（未 unref），`stop()` 后仍保持 event loop 存活最多 10s；(b) 超时时 `pendingRpc` 中的条目**永不删除**（`request` 未传 `timeoutMs`），app-server 不回包时该 Map 单调增长。
建议：改用 `this.request(method, params, { timeoutMs: TIMEOUT_MS })`，让 request 自带的超时路径清理 `pendingRpc`。

**[14] [P2] [codex-process.ts:2186-2191 / 2207-2212 / 2237-2242 + 4893-4906]**
问题：批准/拒绝路径**先 delete 再响应**，而 `respondToServerRequest` 在 transport 已死时只 `console.warn` 吞掉异常；随后仍 `emitToolResult(..., "Approved")` 告诉客户端成功。
证据：
```ts
this.pendingApprovals.delete(pending.toolUseId);
this.respondToServerRequest(pending.requestId, buildApprovalResponse(pending, "accept")); // 内部 catch 静默
this.emitToolResult(pending.toolUseId, "Approved");   // 无论是否真的发出去
```
后果：用户看到“已批准”，app-server 从未收到决策；pending 条目已被删除，无法重试。
建议：`respondToServerRequest` 返回 boolean，失败时不 emit 成功态并向客户端报错。

**[15] [P2] [codex-process.ts:2279-2280 + 2336]**
问题：`installToolSuggestion` 在 `installState === "installing"` 时直接 return，而 `this.request("plugin/install", ...)` 没有超时。app-server 不回包时该 elicitation 永远停在 "installing"，`approve()` 变成静默 no-op，状态永久停在 `waiting_approval`。
证据：
```ts
const currentState = pending.input.installState;
if (currentState === "installing") return;      // 永久早退
...
const result = await this.request("plugin/install", { remoteMarketplaceName, pluginName });  // 无 timeoutMs
```
建议：给 `plugin/install` 加 timeoutMs，超时后把 installState 置回 `failed`。

**[16] [P2] [codex-process.ts:1326-1334]**
问题：`consumeExpectedGoalNotification` 在 `index === -1`（未匹配）时，`.filter` 保留全部条目是对的，但紧接着的 `.map` 仍会把**所有** `cleared` 期望标记为 `interveningGoalEvent: true`。
证据：
```ts
const matched = index >= 0 ? this.expectedGoalNotifications[index] : undefined;
this.expectedGoalNotifications = this.expectedGoalNotifications
  .filter((_, i) => i !== index)                 // index=-1 时不删任何东西
  .map((e) => e.kind === "cleared" ? { ...e, interveningGoalEvent: true } : e);  // 仍无条件标脏
```
后果：一条无法匹配的 `thread/goal/updated`（例如 goal 载荷字段被服务端微调导致 `sameCodexGoal` 失配）会把所有在途 clear 期望标脏，后续真正的 clear 通知走 `verifyAmbiguousClearNotification` 触发一次多余的 `thread/goal/get` 往返 + 一条额外 `goal_state` 广播。
建议：`map` 只在 `matched !== undefined` 时执行。

**[17] [P2] [codex-process.ts:3527-3540]**
问题：`handleStdoutChunk` 的 try 同时包住了 `JSON.parse` 和 `this.handleRpcEnvelope(envelope)`，任何来自通知/审批处理逻辑的异常都会被误报成 “Failed to parse codex app-server output”，并被当作解析错误吞掉。
证据：
```ts
try {
  const envelope = JSON.parse(line) as JsonRpcEnvelope;
  this.handleRpcEnvelope(envelope);              // ← 业务异常也落进同一个 catch
} catch (err) {
  console.warn(`[codex-process] failed to parse app-server JSON line: ...`);
  this.emitMessage({ type:"error", message: `Failed to parse codex app-server output: ...` });
}
```
好的一面是它避免了在 stream `data` 监听器里抛出导致 uncaughtException；坏的一面是真实 bug 被永久伪装成协议解析问题，且该行通知被静默丢弃。
建议：拆成两个 try——parse 一个、dispatch 一个，dispatch 的错误单独打日志分类。

**[18] [P2] [codex-process.ts:4332-4346]**
问题：`pendingPlanCompletion` 直接覆盖赋值，不检查是否已存在未决的 plan 审批。
证据：
```ts
if (this._collaborationMode === "plan" && this.lastPlanItemText) {
  const toolUseId = `plan_${randomUUID()}`;
  this.pendingPlanCompletion = { toolUseId, planText: this.lastPlanItemText };  // 覆盖旧的
```
后果：旧 plan 的 `permission_request` 在客户端永远悬挂（不会收到 `permission_resolved` 或 `tool_result`），且旧 toolUseId 再也无法被 `approve/reject` 命中（2168-2171 只比对当前那一个）。
建议：覆盖前对旧 toolUseId emit 一次 `permission_resolved` + 合成 tool_result。

**[19] [P3] [codex-process.ts:4976-4993]**
问题：`handleServerRequestResolved` 用 `===` 严格比较 `entry.requestId === requestId`，而 `params.requestId` 是 `unknown`、`PendingApproval.requestId` 是 `number | string`。若 app-server 在通知里把数字 id 序列化成字符串（或反之），匹配失败 → pending 条目不被清理、不 emit `permission_resolved`，状态停在 `waiting_approval`。
证据：`const requestId = params.requestId;`（无类型归一化）→ `.find((entry) => entry.requestId === requestId)`。
建议：比较前统一 `String(...)`。

**[20] [P3] [codex-process.ts:3383-3385 + 3514]**
问题：两处死代码/无效语句。`toRpcInput` 永远至少 push 一个 `{type:"text"}`（4745），因此 `input` 不可能为 null，`if (!input) { continue; }` 是不可达分支——但它若真被触发会泄漏 `tempPaths`（没做清理）。`void completion;`（3514）作用于一个已 `await` 的 `undefined`，纯噪音。
建议：删除或补上 tempPaths 清理。

**[21] [P3] [codex-process.ts:3334-3343]**
问题：`emitCompletionEntitiesSnapshot` 每次都对完整 `skillMetadata + appMetadata + pluginMetadata` 做 `JSON.stringify` 生成签名；`skills/changed` / `app/list/updated` 通知可高频到达（虽有 1s cooldown），大 skill 集合下是同步阻塞的重复序列化。
建议：改用增量版本号或对 id 列表哈希。

**[22] [P3] [codex-process.ts:1028-1039 / 1107-1117]**
问题：`waitForPendingThreadSettingsUpdate` / `waitForPendingRuntimeThreadSettingsUpdate` 这两个**读取方**会去写 `this._pendingThreadSettingsUpdate = null`，与写入方 `void operation.then(...)`（910-921 / 1078-1082）里的清理逻辑重复，属于状态所有权混乱。当前不会出错（幂等），但任何一方改动都容易引入竞态。
证据：
```ts
await pending;
if (this._pendingThreadSettingsUpdate === pending) { this._pendingThreadSettingsUpdate = null; return; }
```
建议：清理只由写入方负责，等待方只读。

---

补充一点跨条目的整体判断：**[1]、[2]、[4]、[5]** 是本轮最值得优先修的。其中 [1] 是高频路径上的确定性挂死（每次“turn 先完成、审批后解决”都会中招），[2] 命中的恰好是 “Codex CLI 未安装” 这个最常见的首启失败场景，[4] 的影响范围是整个 Bridge 进程而非单会话。
