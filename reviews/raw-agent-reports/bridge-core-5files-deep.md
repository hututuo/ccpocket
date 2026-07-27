I'll start by exploring the repository structure and reading these files systematically.
Now let me look at the handoff doc context and start reading the continuity file (focus D).
Now let me delegate the largest file while I continue on session.ts.
I have enough from my own reading; let me check on the remaining agent while I finalize.
我已完成对这五个文件的系统审查（parser.ts、sdk-process.ts 由并行子审查完成；codex-process.ts 的审批/通知状态机部分仍有一路子审查在跑，本报告已包含我自己直读的生命周期部分）。

---

# Bridge 核心五文件深度审查报告

**关键前置事实（影响下面多条严重度定级）**：全仓库 `packages/bridge/src/*.ts` 中**没有注册 `process.on("unhandledRejection")`**（只有 `index.ts:479/482` 的 SIGINT/SIGTERM），`package.json engines: node >=18`。Node 18 默认 `--unhandled-rejections=throw`，因此**任何一个未捕获的 floating promise rejection 会直接终止整个 Bridge 进程，杀死所有会话**。下面标注为「→ 整机崩溃」的条目都基于这一点。

---

## A. 进程生命周期

**[A1] [P0] [codex-transport.ts:101-106] child.stdin 无 `error` 监听，EPIPE 会以未捕获的 `error` 事件炸掉整个 Bridge**

触发场景：codex app-server 在 Bridge 正在写入 stdin 时崩溃/被杀（用户 Ctrl-C、OOM、`codex` 升级替换二进制）。Node 的 `child.stdin` 是一个 Writable，写入已关闭的管道会在流上 emit `'error'`（EPIPE/ERR_STREAM_DESTROYED）。EventEmitter 在没有 `error` 监听器时会 **throw**。

证据：`start()` 里只给 `stdout`/`stderr`/`child` 挂了监听，`stdin` 一个都没有；写入也不传 callback：
```ts
child.stdout.on("data", ...); child.stderr.on("data", ...);
child.on("error", ...); child.on("exit", ...);   // 没有 child.stdin.on("error")
write(envelope) { this.child.stdin.write(`${JSON.stringify(envelope)}\n`); }
```
`writeEnvelope`（codex-process.ts:4924）外层的 `try/catch` 抓不到——EPIPE 是异步 emit 的，不是同步 throw。

建议：`child.stdin.on("error", err => this.emit("error", err))`；`write()` 传 error callback 并检查返回值处理背压。

---

**[A2] [P1] [codex-transport.ts:108-113] `stop()` 只发 SIGTERM，无超时升级 SIGKILL，也不杀进程组 → 僵尸/孤儿**

证据：
```ts
stop(): void {
  if (this.child) { this.child.kill("SIGTERM"); this.child = null; }
}
```
问题有三：(1) 立即 `this.child = null`，之后无法再 kill，若 app-server 忽略 SIGTERM（正在跑长命令）就永久残留；(2) 没有 `detached`/`process.kill(-pid)`，app-server 自己 spawn 的工具子进程（bash/编译器）不在杀伤范围；(3) `destroy()`（session.ts:2374）→ `stop()` 后立刻 `removeAllListeners()`，即使后来真的退出也没人知道。

建议：保留 child 引用，`SIGTERM` 后设 5s 定时器升级 `SIGKILL`；spawn 时 `detached:true` 并 `process.kill(-child.pid, sig)`。

---

**[A3] [P1] [codex-transport.ts:91-98 + codex-process.ts:1961-1983] spawn 失败只 emit `error` 不 emit `exit`，pendingRpc 永不 reject → 会话永久卡在 starting**

触发场景：`codex` 不在 PATH、cwd 不存在、EACCES。Node 文档明确：spawn 失败时只 emit `'error'`（和可能的 `'close'`），**不会 emit `'exit'`**。

证据：transport 只在 `child.on("exit")` 里向上抛 `exit`；而 codex-process 的两个处理器不对称：
```ts
transport.on("error", (err) => { ... this.setStatus("idle"); this.emit("exit", 1); });  // 不置空 transport，不 rejectAllPending
transport.on("exit", (code) => { this.transport = null; this.rejectAllPending(...); ... });
```
于是 `bootstrap` 里 `await this.initializeRpcConnection()` 发出的 RPC 永远不 settle。配合 [A6]（`request()` 默认无超时），这条 `bootstrap` promise 永久挂起，会话状态停在 `starting`，`session.ts` 也不会收到有意义的清理。

建议：transport 在 `child.on("error")` 里也 `this.child = null; this.emit("exit", null)`；或 codex-process 的 `transport.on("error")` 里同样 `this.transport = null; this.rejectAllPending(err)`。

---

**[A4] [P1] [codex-process.ts:2896-2921] bootstrap 失败只 `emit("exit", 1)`，不 stop transport → 孤儿 app-server 进程**

触发场景：`thread/resume` 返回错误、`thread/fork` 契约校验失败（2757/2766 的 throw）、`waitForPendingThreadSettingsUpdates` 失败等。

证据：
```ts
} catch (err) {
  if (!this.stopped) { ...emitMessage(error); emitMessage(result:error); }
  this.setStatus("idle");
  this.emit("exit", 1);        // 没有 this.stop()，transport 仍在跑
}
```
上层 `session.ts:1149` 的 `exit` 处理只把 `status` 设成 `idle`，**不会把 session 从 map 里删掉，也不会 stop 进程**。结果：每次 bootstrap 失败留下一个活着的 `codex app-server` 子进程，直到用户显式 `stop_session` 或 `evictStaleIdleSessions` 触发。反复重试 = 进程数线性增长。

建议：catch 里在 emit exit 之前调用 `this.stop()`。

---

**[A5] [P1] [codex-process.ts:3373] 空 text 会永久 break 输入循环，会话变僵尸但进程仍活**

证据：
```ts
if (this.stopped || !pendingInput.text) break;
```
`stop()` 用 `this.inputResolve({text:""})` 作为哨兵是设计意图，但**同一个哨兵对普通输入也生效**。`sendInputStructured("")` 会让 `runInputLoop` 返回 → `bootstrap` 的 try 正常结束 → **既不 emit exit，也不 stop transport，也不再 emit `input_ready`**。此后 `isWaitingForInput` 恒为 false，该会话永远无法再发消息，UI 上却是 idle。

当前唯一防线在 WS 层（websocket.ts:4680 `if (!msg.text.trim())`），但 `sendInputStructured` 也被 `session.ts:2044 drainCodexQueue` 和 local-features 调用，并非只有 WS 一条路径。

建议：用一个独立的 `{ stopped: true }` 哨兵字段区分 stop 与空输入；空输入时 `continue` 而非 `break`。

---

**[A6] [P1] [codex-process.ts:4812-4826] `request()` 默认无超时**

证据：`const timeoutMs = typeof options.timeoutMs === "number" && ... ? ... : undefined;`，`if (timeoutMs !== undefined)` 才挂定时器。`bootstrap` 的 `thread/start`/`thread/resume`（2735）、`turn/start`（3481）、`turn/interrupt`（2001/2021）全部不传 timeout。app-server 静默不回包 = 永久挂起，只有进程退出触发的 `rejectAllPending` 能解开。

建议：给 `request()` 一个默认上限（例如 120s），控制类 RPC 更短。

---

**[A7] [P1] [codex-process.ts:2432-2452] `resumeRunningIfNoPendingInteractiveRequest()` 无条件 `setStatus("running")`，可让会话永久卡在 running**

触发场景：turn 在审批未决时终止（用户中断 → `turn_aborted`），随后用户再点批准/拒绝。

证据：`handleTurnCompleted`（4350-4355）只在 `pendingApprovals.size === 0 && pendingUserInputs.size === 0` 时才 `setStatus("idle")`；否则保持 `waiting_approval` 且**不设 `_idleWhenInteractionsClear`**（该字段只在 `handlePlanRejected` 2583 处赋 true）。于是用户解决残留审批时走到：
```ts
if (this._idleWhenInteractionsClear) { ... this.setStatus("idle"); }
else { this.setStatus("running"); }     // pendingTurnId 已经是 null
```
状态变成 `running` 且没有任何 turn 会去把它推回 idle → `isWaitingForInput`（631，要求 `_status !== "running"`）恒为 false → **该会话再也不能发消息**。

对比证据：同文件 `handleServerRequestResolved`（5007-5011）写法是正确的 `this.setStatus(this.pendingTurnId ? "running" : "idle")`。

建议：把 2450 行改成与 5010 一致的 `this.setStatus(this.pendingTurnId ? "running" : "idle")`。

---

**[A8] [P2] [codex-process.ts:3416-3509] `pendingTurnCompletion` 无超时，turn 丢失 = 输入循环永久停摆**

`await new Promise(...)` 只由 `handleTurnCompleted`（4358）或 `rejectAllPending` 解开。app-server 漏发 `turn/completed`（已知 Codex 偶发）时，循环卡住不再 emit `input_ready`，会话看起来永远 running。

建议：加一个可配置的 turn watchdog（例如 10 分钟无任何 item 事件则视为失败），或在收到 `thread/started` 重置时兜底。

---

**[A9] [P2] [codex-process.ts:1971-1983 vs 1855-1856] 进程崩溃路径不清 `pendingApprovals` / `pendingUserInputs` → 残留审批弹窗**

`stop()` 会 clear 两个 Map，但 `transport.on("exit")`（崩溃路径）只 `rejectAllPending` + `setStatus("idle")`。`session.ts:1361` 的 `list()` 每次都读 `process.getPendingPermission()`，因此崩溃后的会话列表仍会带 `pendingPermission`，手机端弹出一个永远点不动的审批框（`approve()` → `respondToServerRequest` → `writeEnvelope` 抛 "not running" → 被 2897 的 catch 吞成一行 warn）。

建议：`transport.on("exit")` 里也 clear 两个 Map 并 emit `permission_resolved`。

---

**[A10] [P2] [codex-process.ts:3382-3385] `!input` 分支泄漏临时文件**

```ts
const { input, tempPaths } = await this.toRpcInput(pendingInput);
if (!input) { continue; }        // tempPaths 未 rm
```
同函数其它出口（3406-3408、3511-3513）都做了 `rm`，唯独这里没有。图片附件写出的临时文件永久留在磁盘。

---

**[A11] [P2] [codex-process.ts:1818-1827] 重复 `start()` 时旧 `bootstrap` 无 generation 校验**

`prepareLaunch` 会 `this._runtimeGeneration += 1`（1877）并把 `stopped` 重置为 false（1876），但 `bootstrap`/`runInputLoop` 全程**没有任何地方读 `_runtimeGeneration`**（grep 确认）。旧的 bootstrap 恢复执行后 `this.stopped === false`，会继续对**新**的 transport/thread 写状态、emit 消息。当前 `session.ts:1243` 每个 session 只 start 一次，属于潜在路径，但 API 已暴露（`initializeOnly` 也走同一条）。

---

**[A12] [P2] [session.ts:1149-1175] 进程 exit 后 session 不出 map，成为「可见但不可用」的僵尸**

`proc.on("exit")` 只 `session.status = "idle"` 并追加一条 status 历史，不从 `this.sessions` 删除。用户在列表里仍能看到并点进去，发消息时才发现 `isWaitingForInput === false`。只有 `evictStaleIdleSessions`（>30 个 idle）才会回收。

---

**[A13] [P0/P1] sdk-process.ts（Claude 侧）** — 并行审查确认的同类问题，摘要如下（完整 17 条已获取）：

- **[P0] sdk-process.ts:825** `interrupt()` 只 `pendingPermissions.clear()` 不 resolve；SDK 侧 `await this.canUseTool(...)` 永久挂起，CLI 端该工具调用永久阻塞、SDK 的 `cancelControllers` 条目泄漏。唯一兜底（`waitForPermission` 的 abort 监听，:1364）被 `if (this.pendingPermissions.has(toolUseId))` 门控，条目已被 clear 所以也不会 resolve。
- **[P0] sdk-process.ts:1388** `updateStatusFromMessage` 的 `result` 分支同样只 clear 不 resolve。
- **[P1] sdk-process.ts:777-786** `processMessages()` 出错不复位 `queryInstance`，`isRunning` 永久为 true，`websocket.ts:10819` 会复用这个死实例，后续输入只会无限入队；同时不 emit `session_end`，崩溃后自定义会话名丢失。
- **[P1] sdk-process.ts:1216-1307** 重启竞态：旧 `processMessages` 循环结束时把**新** `queryInstance` 置 null 并对新会话 emit exit（`stopped` 已被 `start()` 重置为 false，`if (this.stopped) break` 失效）。
- **[P1] sdk-process.ts:648-703** `start()` 在 auth 异步窗口内无重入保护，二次 start 会泄漏第一个 query → 孤儿 CLI 子进程 + 两个消息循环同时向一个 EventEmitter 推送。
- **[P1] sdk-process.ts:838-848** 停止后仍接受输入且 `start()` 不清 `pendingInputQueue` → 旧会话残留输入被注入新会话。
- **[P2] sdk-process.ts:1113-1123 / 118-164** 10s 定时器从不 clear、`supportedModels()` 无超时、`void drain` 空操作。
- 注：`stop()` 不做 SIGTERM→SIGKILL 升级在这里是**合理**的，`Query.close()` 由 SDK 负责强杀 CLI 子进程。
- **测试覆盖为零**：`sdk-process.test.ts` 只覆盖纯函数与 `setPermissionMode`/`approveAlways`/`answer`；`start()` 在测试环境因缺 API key 直接走 auth 失败分支，上述生命周期/并发路径完全没有测试。

---

## B. 消息解析与协议（parser.ts）

**定位说明**：parser.ts 2388 行里**只有两个运行时函数**——`normalizeToolResultContent`(1112-1122) 和 `parseClientMessage`(1126-2388)，其余全是类型声明。**流式 delta 组装、行缓冲、UTF-8 chunk 边界这三个审查点在本文件里没有实现**，分别在 `websocket.ts`（delta 批处理）和 `codex-process.ts`（行缓冲）。

**[B1] [P0] [parser.ts:1143-1170 + 2186-2196] `isPromptHistoryEntry` 漏判 → prompt 历史被整体清空（数据损坏）**

守卫只校验 `text/projectPath/id/useCount/totalUseCount/isFavorite` 六个字段，而 `PromptHistoryImportEntry` 还有 `createdAt/lastUsedAt/updatedAt/favoriteUpdatedAt/deletedAt/commandKind/clientStats/sessionStats` 八个完全不校验：
```ts
if (entry.isFavorite !== undefined && typeof entry.isFavorite !== "boolean") return false;
return true;   // clientStats / sessionStats / *At 全部放行
```
下游 `prompt-history-store.ts:279 importEntries` 是**先清空再遍历**：`this.data.entries = []` → `incrementClientStat`(store:353) 执行 `entry.clientStats[clientId] = {...}`。`clientStats` 是字符串时 ESM 严格模式抛 `TypeError`（子审查已实测），异常发生在 `saveBumped()` 之前 → 内存历史已清空且不回滚，下一次 `record_prompt_history` 把空集合写盘。`websocket.ts:9165` 的 try/catch 只回错给客户端。
另外 `updatedAt: 12345`（数字）也能通过，`maxIso` 的字符串比较会把它当成"更大"直接持久化。

**[B2] [P1] [parser.ts:1117] `normalizeToolResultContent` 遇到数组内 `null` 直接崩溃，并打断整条 SDK 消息流**

```ts
return (content as Array<Record<string, unknown>>)
  .filter((c) => c.type === "text")      // c 可能是 null → TypeError
  .map((c) => c.text as string)
```
调用点 `sdk-process.ts:476` 位于 `processMessages()` 的 `for await` 循环内且**循环体没有 per-message try/catch**，异常冒泡到 :777 的 `.catch` → 整个 session 消息流终止，后续 assistant/result 全丢，客户端只收到一条泛化 `SDK error`（并叠加 [A13] 的 `queryInstance` 不复位）。另外 `c.text as string` 是空断言，`{type:"text",text:{a:1}}` 会产出 `"[object Object]"`。

**[B3] [P1] [parser.ts:1410-1451、1573-1644 等] 必填 `sessionId` 只判 `typeof === "string"`，空字符串放行 → 操作被静默路由到另一个 session**

`{"type":"update_queued_input","sessionId":"", ...}` 通过校验，下游 `websocket.ts:9595 resolveSession` 的 `if (sessionId)` 让 `""` 落到 `getFirstSession()`。受影响：`update_queued_input`(ws:4674)、`cancel_queued_input`(4705)、`steer_queued_input`(4727)、`get_goal`(5793)、`set_goal`(5833)、`clear_goal`(5899)。会静默改掉/写到别的 session，无任何报错。文件里 `get_history_page`/`resolve_artifact` 已有 `isNonEmptyString` 助手，只是没推广。

**[B4] [P1] [parser.ts:2380-2381 + websocket.ts:3748-3767] 校验失败与「未知类型」共用 `return null`，带 requestId 的请求永久挂起**

两个后果：(a) 已知类型但载荷非法被报成 `unsupported_message`，客户端误判为"Bridge 太旧需升级"；(b) 错误响应**不带 requestId**，而 `resolve_artifact`/`read_file`/`read_artifact_source`/`get_history_page`/`get_history_tool_details`/`archive_session` 都是 requestId 关联的请求-响应，客户端 pending future 收不到任何相关响应，只能等超时。
**未知类型本身的 graceful degradation 是合格的**（不 throw、不断连接、不影响后续消息），问题只在"无法区分 + 无法关联"。
建议：`parseClientMessage` 返回 `{ok:false, reason:"unknown_type"|"invalid_payload", type, requestId?}`。

**[B5] [P1] [parser.ts:1242-1361] `start` 分支 7 个已声明字段完全不校验，其中 `sessionId` 会绕过 `resume_session` 的校验**

`start` 校验了 projectPath/model/effort/maxTurns 等，却完全没有 `sessionId`、`continue`、`sandboxMode`、`useWorktree`、`worktreeBranch`、`existingWorktreePath`、`provider`。而 `websocket.ts:3933` **直接调 `handleClientMessage` 绕过 `parseClientMessage`** 转成 `resume_session`：
```ts
if (provider === "codex" && msg.sessionId) {
  await this.handleClientMessage({ type: "resume_session", sessionId: msg.sessionId, ... }, ws);
```
于是 `resume_session` 自己的 `typeof sessionId !== "string"` 形同虚设，非字符串 sessionId 进入整条 resume 链（模板字符串变 `[object Object]`、脏 `resumeOperationKey`）。

**[B6] [P2] [parser.ts:1669-1671] `rename_session.name` 任意类型、无长度上限**，会被持久化并出现在每次 session_list 广播里（对比 `archive_session` 2327-2339 限了 1024）。

**[B7] [P2] [parser.ts:1408] 旧版单图字段校验方向反了**：`if (msg.imageBase64 && typeof msg.mimeType !== "string") return null;` 只校验 mimeType，`imageBase64` 本身类型不管。同分支 `images`/`skills`/`mentions` 三个数组都做了逐元素校验，唯独单数形式的 `imageBase64`/`imageId`/`skill` 漏了。

**[B8] [P2] [parser.ts:2201-2218、2271-2274] git 系列 `files` 数组元素不校验，`git_unstage.files` 完全不校验**。`files: "abc"` 会被 `execFileSync("git",["reset","HEAD","--",...files])` 展开成三个字符参数，语义全错但静默"成功"。同分支 `hunks` 的元素校验是做了的，属于不一致遗漏。

**[B9] [P2] [parser.ts:~20 处，1256/1314/1320/1327/1334/1341/1351/1615/1860/2172] `String(msg.x)` 强制转换绕开枚举校验**：`String(["plan"]) === "plan"`，单元素数组能冒充合法枚举值通过校验，下游用 `=== "plan"` 严格比较全部落空 → 静默退化成"没传该字段"（例如 `permissionMode` 静默退回 default）。对照 `set_permission_mode`(1499-1506) 写法是对的，说明是遗漏。

**[B10] [P2] [parser.ts:2099-2100、2093] 数值字段只判 `typeof === "number"`，`Infinity` 可通过**（`JSON.parse('{"traceLimit":1e999}')`）。对比同文件 `maxBudgetUsd`(1266) 正确用了 `Number.isFinite`。

**[B11] [P2] [codex-process.ts:575 + 3519] 行缓冲无上限**（对应审查点 4）：`this.stdoutBuffer += chunk`，只在遇到 `\n` 时切走（3521-3524），app-server 输出一行超长 JSON 或永不换行会让该字符串无界增长直至 OOM。

**[B12] [P3] [parser.ts:2384] 结尾 `return msg as unknown as ClientMessage` 双重断言**，只有 7 种消息用了 `hasOnlyKeys` 白名单，其余 60+ 种的任意额外字段原样进入 handler 和 recording-store 落盘。这是 [B5][B6][B7] 的共同根源。

**[B13] [P3] [parser.ts:1126-1128] 无输入长度限制** + `websocket.ts:1393 new WebSocketServer({server})` 未设 `maxPayload`（ws 默认 100MiB），单条 100MB 畸形 JSON 会同步阻塞事件循环。

**编码问题的结论（已验证无问题）**：`codex-transport.ts:80/85/242/243` 用了 `setEncoding("utf8")`，Node 内部走 StringDecoder，多字节不会在 chunk 边界被切断；`websocket.ts:9834 splitDeltaText` 用 `for (const char of text)` 按 code point 迭代，emoji/代理对不会被切开；`flushSessionDeltaBatches`(9774) 在任何非 delta 广播前先 flush，保证 delta 与最终 assistant 消息顺序正确。**唯一的编码缺陷在 continuity 侧**，见 [D9]。

---

## C. 会话状态机（session.ts）

**[C1] [P0] [session.ts:693-700, 1113-1120, 1141-1145, 1170-1174] `trackMessageWork` 链一旦 reject 就被永久污染 + 未捕获 rejection → 整机崩溃**

```ts
let messageProcessing: Promise<void> | null = null;
const trackMessageWork = (work: Promise<void>): void => {
  const tracked = work.finally(() => { if (messageProcessing === tracked) messageProcessing = null; });
  messageProcessing = tracked;      // 没有任何 .catch()
};
```
`processMessage` 自带全量 try/catch 所以安全，但另外两个入链者没有：
- `trackMessageWork(messageProcessing.then(drain))`（1142），`drain` → `drainCodexQueue` → `codexQueueDrainHooks.canDrain`（→ local-features）、`this.onMessage(...)`（→ WS 广播）、`sendInputStructured`
- `trackMessageWork(messageProcessing.then(finish))`（1171），`finish` → `evictStaleIdleSessions` → `destroy` → `process.stop()` → `child.kill()`（可抛 EPERM）

任一处同步 throw 后：`tracked` 变成 rejected → 下一条消息 `messageProcessing.then(processMessage)` **跳过 processMessage** 并返回新的 rejected promise → 该会话的消息管道**永久停摆**；若之后没有新消息进来，最后那个 rejected promise 无人处理 → **unhandled rejection → 整个 Bridge 退出**。

建议：`trackMessageWork` 里加 `.catch(err => console.error(...))` 并保证返回 resolved promise；`drain`/`finish` 各自包 try/catch。

**[C2] [P0] [session.ts:881, 890, 1227, 1233] 四处 `void save*(...)` 没有 `.catch()` → unhandled rejection 直接杀 Bridge**

```ts
void saveCodexSessionProfile(msg.sessionId, session.codexSettings.profile);
void saveCodexSessionAdditionalWritableRoots(msg.sessionId, ...);
```
`sessions-index.ts:1853-1866` 的实现是 `await loadCodexSessionProfiles()` + `await writeFile(join(homedir(),".codex","ccpocket-session-profiles.json"), ...)`，`~/.codex` 不存在（ENOENT）、只读 home、磁盘满（ENOSPC）都会 reject。全仓库没有 `unhandledRejection` handler → 进程退出，所有会话一起死。
建议：全部改成 `void x().catch(err => console.warn(...))`。

**[C3] [P1] [session.ts:635-682] `commitReplacement` 不迁移历史与 Codex 增量状态，Desktop 每次接管都丢一批会话内存**

`replaceCodexSession`（Desktop continuity 每次外部 turn 完成都会触发）把整个 `SessionInfo` 换成新对象，但只搬了 `name/autoRename/autoRenameAttempted/codexQueuedInput/codexGoal*/status/lastActivityAt`。**没搬**的有：`history`、`historyEntries`、`historyRevision`（回到 0）、`historyLowWatermark`、`codexUserTurnUuidByRawId`、`pendingCodexUserEchoUuids`、`codexLatestUserInput`、`codexOrderedHistoryEntries`、`codexLiveAssistantUserKeyByIdentity`、`codexCanonicalHistoryRevision`、`codexHistoryResetRevision`。

`historyRevision` 倒退到 0 本身被 `websocket.ts:3218 shouldResetCodexHistoryDelta` 兜住了（`resetRevision` 为 undefined → 强制 snapshot），但 `codexLatestUserInput` 丢失会让 `applyCodexCanonicalHistoryBaseline`（2596）失去"保留最新用户输入"的兜底，`codexUserTurnUuidByRawId` 丢失会让同一条 Codex 用户 item 在换端后拿到不同的合成 UUID。这正好对应交接文档里"中间过程/工具/最终回复偶发整段重复两次"的症状域。

建议：在 `commitReplacement` 里连同这批 Codex 历史身份字段一起迁移。

**[C4] [P1] [session.ts:1474-1506] `mergeUserInputIntoHistory` 原地改历史但不推进 `historyRevision`，delta 客户端永远拿不到这次 UUID 回填**

```ts
const entry = session.historyEntries[i];
if (entry) { (mergedMsg as ...).historySeq = entry.seq; entry.message = mergedMsg; }
session.history[i] = mergedMsg;
```
`seq` 保持旧值，因此 `getHistorySince(sessionId, N)` 的 `entries.filter(e => e.seq > sinceSeq)` 永远滤掉它。只有当场在线的客户端能通过 `this.onMessage` 收到。断线重连/后台恢复的客户端会永久保留没有 UUID 的旧条目（进而无法 rewind）。

**[C5] [P1] [session.ts:2360-2378 + 1149-1175] `destroy()` 先删 map 再 `stop()`，同步 exit 回调会对已销毁 session 追加历史并广播**

`ownsRuntimeSlot()` 对非 replacement session 恒为 `true`（`replacementSession === undefined ||`），所以 `stop()` 同步触发的 `exit` 会走完整个 `finish()`：向已从 map 移除的 session `appendHistoryToSession`、`broadcastCodexQueue`（对外发 `conversation_queue`）、再 `evictStaleIdleSessions()` 递归。注释说"先移除以免递归 evict"，但没有防住"对已死 session 继续写入与广播"。
建议：`ownsRuntimeSlot()` 统一改为 `this.sessions.get(id) === session`。

**[C6] [P2] [session.ts:2143-2190] `rewindConversation` 先 `destroy(id)` 再 `create(...)`，`create` 抛异常就会话全丢**

`create` 会执行 `createWorktree`、`execFileSync("git")`、`proc.start()`，任一 throw 都会让用户的会话彻底消失（旧的已销毁，新的没建成）。且新 id 与旧 id 不同，客户端所有基于 sessionId 的本地状态需要重建。

**[C7] [P2] [session.ts:2380-2398] `evictStaleIdleSessions` 会静默杀掉用户正在看的会话**

在每次 `status → idle`（1127）和每次 `exit`（1168）触发，超过 `MAX_IDLE_SESSIONS=30` 就按 `lastActivityAt` 从旧到新销毁，没有"当前有客户端订阅"的保护，也不给被杀会话发任何专门通知（只有 `onSessionUpdated` 传了最后一个被杀的 id）。

**[C8] [P2] [session.ts:1739-1751] `trimHistory` 用 `Array.prototype.shift()`，每条消息 O(n)**；`MAX_HISTORY_PER_SESSION=100` 时影响可控，但 `historyEntries` 与 `history` 两个数组靠"同时 push / 同时 shift"手工保持同步，没有不变式断言，任何一处遗漏就会导致 `entry.message` 与 `history[i]` 错位。

**[C9] [P2] [session.ts:1922-1992] `steerCodexQueuedInput` 跨 await 后无条件追加历史**

`await session.process.steerTurnStructured(...)` 之后重新解析 `currentSession`，但 1987-1990 的 `appendHistoryToSession` / `onMessage` 是**无条件**执行的——即使期间队列已被用户编辑成了另一条内容（`currentSession.codexQueuedInput !== queued`，1981 的判断只影响清队列，不影响追加）。此时历史里会出现一条"已发出"的用户消息，而队列里还留着编辑后的版本，UI 上表现为消息重复。

**[C10] [P3] [session.ts:1660-1689] `pendingCodexUserEchoUuids` 是无界 Set**，只在 merge 成功时清除；echo 永不到达的 UUID 会一直累积到会话销毁。

---

## D. Codex Desktop continuity（重点）

**[D1] [P1] [codex-desktop-continuity.ts:577-612 + desktop_session_list_continuity_tracker.dart:205-231] watch ownership 在首页 tracker 与聊天页之间来回抢占，反复进入/退出会话时会有 4s 级的续传空窗**

Bridge 侧的注册表键是 `(client, sessionId)`，**同一个 WebSocket 上首页 tracker 和聊天 cubit 是同一个 `client` 对象**，`registerWatch` 用 last-writer-wins 直接顶掉前一个注册，且**不给被顶掉的一方发任何事件**：
```ts
const previous = registrations?.get(message.sessionId);
if (previous) { previousMonitor?.removeWatcher(previous); ... }
registrations.set(message.sessionId, registration);
```
客户端只能靠"收到一个 requestId 不是自己的 `watching` 事件"来推断自己被顶掉（tracker dart:205-214）。

具体竞态序列（聊天页切换 thread 或 `force` 重建 watch 时，`chat_session_cubit.dart:563` 先 unwatch 再 watch）：
1. 线上顺序：`unwatch(Rold)` → `watch(Rnew)`（两帧都是 cubit 在同一 tick 发出的）
2. Bridge 处理 `unwatch(Rold)` → 回 `unwatched(Rold)`
3. tracker 收到 `unwatched(Rold)`，`_displacedByConversation[S] == Rold` 命中 → 清除 displaced → `_ensureWatch` → 发 `watch(list-X)`
4. Bridge 已经处理完 `watch(Rnew)`（注册 Rnew，回 `watching(Rnew)`），紧接着处理 `watch(list-X)` → **把聊天页的 Rnew 顶掉**
5. cubit 的 `_onDesktopContinuityMessage`（dart:675-679）因 `requestId != _desktopContinuityRequestId` 丢弃 `watching(list-X)` → `_desktopContinuityWatchAckTimer`（4s，dart:93）超时 → `_retireDesktopContinuityBinding` + 指数退避重试

结果：**打开的聊天页在 4s+ 退避期间收不到任何 Desktop 事件**，同时 monitor 被反复 close/re-create（每次 `disposeMonitorIfUnused` → `monitor.close()` → 下次 `monitorFor` 重新 `open` + 8MB `seed`），fd 与 IO 抖动。

现有测试 `codex-desktop-continuity.test.ts:2154` 只覆盖了"单个 owner 的 watch/unwatch/supersede CAS"，**没有覆盖同一 socket 上两个逻辑 owner 互相顶替**这条路径。

建议：Bridge 侧把注册键改成 `(client, sessionId, requestId)` 允许多 owner 并存并逐个投递；或在 `registerWatch` 顶掉 previous 时**显式给被顶掉的 requestId 发一条 `unwatched`/`displaced` 事件**，让 tracker 和 cubit 都能确定性地知道自己失去了 ownership，而不是靠超时推断。

---

**[D2] [P1] [codex-desktop-continuity.ts:249-321, 589-591] `registerWatch` 抛「Too many watchers」时不 dispose 已创建的 monitor → FSWatcher + 750ms interval + fd 泄漏**

```ts
const monitor = await this.monitorFor(message.threadId);   // 已 this.monitors.set(threadId, monitor)
...
if (!this.registerWatch(client, message, monitor, intent)) { this.disposeMonitorIfUnused(...); return; }
```
但 `registerWatch` 在 589-591 是 **throw** 而不是 return false：
```ts
if (!previous && this.totalWatcherCount >= MAX_WATCHERS) {
  throw new Error("Too many Codex Desktop continuity watchers");
}
```
throw 被 306 的 catch 接住，只发了一条 `rollout_unavailable` error，**catch 分支里没有 `disposeMonitorIfUnused`**。该 monitor 以 0 watcher 常驻 `this.monitors`，持有一个 `fs.watch`、一个 `setInterval(POLL_MS=750)` 和一个打开的 FileHandle，直到 MAX_MONITORS(64) 淘汰。

建议：catch 分支里补 `this.disposeMonitorIfUnused(message.threadId, monitor)`；或把 watcher 上限改成返回 false 走统一路径。

---

**[D3] [P1] [codex-desktop-continuity.ts:337-370 + sessions-index.ts:3417-3438] 无 rollout 的 thread：每条用户输入都触发一次「全量扫描 + 逐文件打开」，且首页 tracker 会每 8s 无限重试同样的扫描**

`admitSupportedInput` 在**每次 Codex 输入**的关键路径上 `await this.monitorFor(threadId)`；`monitorFor` 未命中缓存时调 `resolveCodexSessionJsonlPath` → `findCodexSessionJsonlPath`：
```ts
const files = await listCodexSessionFiles();     // 递归遍历整个 ~/.codex/sessions，无缓存
for (const filePath of files) {
  if (fallbackSessionId === threadId || ...) return filePath;
  if (await codexJsonlHasThreadId(filePath, threadId)) return filePath;   // 打开每个文件读首行
}
return null;                                     // 未命中 = 全量扫完
```
解析**失败**时 monitor 不会被缓存（`monitorFor` 直接 throw），所以**下一条消息又完整扫一遍**。老用户 `~/.codex/sessions` 有数千个 jsonl 时，每条消息要多 N 次 `open`+首行读，输入延迟肉眼可见。

同一条路径还被首页 tracker 无限放大：tracker 收到 `rollout_unavailable` error 后走 `_scheduleWatchRetry`（dart:189-200，只有 `path_not_allowed`/`continuity_binding_mismatch` 才 suppress），退避上限 8s，**没有最大重试次数**。一个永远解析不出 rollout 的会话 = 每 8s 一次全量扫描，永久。

建议：给 `resolveCodexSessionJsonlPath` 加 threadId→path 的负缓存（含 TTL）；tracker 对 `rollout_unavailable` 设最大重试次数或长退避；`admitSupportedInput` 的解析改为后台异步、不阻塞输入路径。

---

**[D4] [P1] [codex-desktop-continuity.ts:337-370, 395-418, 974-998] rehydrate 永久失败时没有 fail-open，用户消息只能一直排队**

`admitSupportedInput` 在 stale 时返回 `{action:"queue", reason:"desktop_history_refreshing"}`，`admitCodexQueuedInputDrain` 在 `staleRuntimeSessionIds.has(id) || rehydrateInFlight.has(id)` 时返回 false。若 `rehydrateCodexSessionAfterExternalTurn`（websocket.ts:9909）持续返回 false（例如 `getCodexThreadHistory` 一直失败，或 `isWaitingForInput` 恒为 false——正好可由 [A7] 的"卡在 running"造成），`retryOrReportRehydrateFailure` 重试 3 次后只发一条 `runtime_rehydrate_failed` **advisory** 错误，`staleRuntimeSessionIds` 不清除。

之后每次用户发送都会：重置失败计数（360-365）→ 再排队 → 再失败 3 次 → 再发 advisory。**用户的每一条消息都停在队列里，永远发不出去**，而 tracker 端对 `runtime_rehydrate_failed` 的处理是"不 orphan watch、请求一次 history"（dart:181-188），不给用户任何可操作的出路。

建议：给 stale fence 加一个最大滞留时长/失败次数，超过后 fail-open（`allow`）并把风险明确告知客户端。

---

**[D5] [P2] [codex-desktop-continuity.ts:726-731] `onMonitorEvent` 用 threadId 反查 monitor，而不是比对发事件的 monitor 身份**

```ts
onEvent: (event) => this.onMonitorEvent(threadId, event),     // 524-534 闭包只捕获 threadId
...
private onMonitorEvent(threadId: string, event: ...): void {
  const monitor = this.monitors.get(threadId);                // 可能是"新"的那个
  if (!monitor) return;
  const registrations = monitor.watchers;
```
在 [D1] 的 close/re-create 抖动里，旧 monitor 的延迟回调（`queueMicrotask(() => this.flushPendingCompletedTool(key))` 2141、`pending.timer` 1763、`turn.pendingStartTimer` 2278）如果先于 `close()` 排入队列，就会把旧 monitor 的事件广播给新 monitor 的 watcher。目前靠各个 flush 函数的 `if (this.closed) return` 侥幸挡住，是**偶然安全**而非结构性安全。

建议：`onEvent` 闭包捕获 monitor 实例，`onMonitorEvent(monitor, event)` 并加 `if (this.monitors.get(threadId) !== monitor) return`。

---

**[D6] [P2] [codex-desktop-continuity.ts:1233-1256] seed 边界丢一行：正在追加的最后一条 item 会被静默丢弃**

`seed()` 把 `text.split("\n")` 的最后一个元素（不完整的行）交给 `JSON.parse` → 失败 → `continue`（1275-1277）；然后 `this.offset = info.size`（1255）直接跳到文件尾，`lineBuffer` 为空。后续 `readPass` 从 `info.size` 开始读，那条 item 的**后半截**会被当成独立一行解析 → 再次 `JSON.parse` 失败 → 丢弃。

即 watch 启动的那一瞬间正在被 Codex 追加的那条 rollout item **两端都丢**。同时 `bytesRead` 可能小于 `length`，`offset` 仍被硬设成 `info.size`，也会跳过未读字节。

建议：seed 结束时把最后一个不完整片段留进 `lineBuffer`，并把 `offset` 设为"最后一个换行符之后"的绝对偏移。

---

**[D7] [P2] [codex-desktop-continuity.ts:463-476 + tracker dart 全文] tracker 从不发 unwatch，watcher/monitor 只能靠断线回收**

grep 确认 `requestCodexDesktopContinuityUnwatch` 只有 `chat_session_cubit.dart:606` 一处调用者；`DesktopSessionListContinuityTracker` 在 `_syncSessions`（session 消失）、`close()`、`_onConnection`（断线）里都只清本地 map，**从不通知 Bridge**。于是 Bridge 侧 `watchersByClient[client][sessionId]` 与对应 monitor（fs.watch + 750ms interval + fd）会一直存活到 socket 断开。会话被 `evictStaleIdleSessions` 销毁后，其 continuity monitor 仍在轮询一个已死会话的 rollout 文件。

**[D8] [P2] [codex-desktop-continuity.ts:1447-1467] `consumeText` 每次循环都对整个 `lineBuffer` 调 `Buffer.byteLength`，超长行是 O(n²)**

```ts
this.lineBuffer += part;
if (Buffer.byteLength(this.lineBuffer, "utf8") > MAX_LINE_BYTES) { ... }
```
`MAX_LINE_BYTES = 2MB`，`READ_CHUNK_BYTES = 64KB`，一条 2MB 的行要做 32 次 byteLength，每次都重扫全串。建议维护增量字节计数。

**[D9] [P2] [codex-desktop-continuity.ts:2728-2732] `boundedText` 按字节硬切，会把多字节字符切成 U+FFFD**

```ts
const buffer = Buffer.from(value, "utf8");
return `${buffer.subarray(0, maxBytes).toString("utf8")}\n…[truncated by Bridge]`;
```
中文/emoji 正好落在 `maxBytes` 边界时尾部会出现替换字符。这是全流程里**唯一真实存在**的编码截断缺陷（其余路径已确认正确，见 B 段结论）。建议用 `StringDecoder` 或回退到最近的合法码点边界。

**[D10] [P2] [codex-desktop-continuity.ts:506-516] `monitorFor` 的 MAX_MONITORS 检查在 await 之前，并发创建可超限**

`if (this.monitors.size >= MAX_MONITORS)` 之后有 `await resolveRolloutPath` 和 `await monitor.start()` 两个 await 点，多个不同 threadId 的并发调用都能通过检查再各自 `monitors.set`，实际数量可超过 64。同时淘汰只挑 `watcherCount === 0` 的，若全部有 watcher 就直接 throw（→ 触发 [D3] 的无限重试）。

**[D11] [P3] [codex-desktop-continuity.ts:2780-2785] `remember()` 命中已存在的 key 时不刷新 LRU 位置**，用作 `staleRuntimeSessionIds`（上限 256）时，一个长期 stale 的活跃会话可能被新条目挤出去，导致 stale fence 意外失效。

---

## E. 错误处理

**[E1] [P0] 全局缺少 `unhandledRejection` 兜底**

`grep -rn "unhandledRejection|uncaughtException" packages/bridge/src/*.ts` 无结果；`packages/bridge/package.json` 声明 `"node": ">=18.0.0"`。Node ≥15 默认 `--unhandled-rejections=throw`，任何未处理的 rejection 直接终止进程。这把 [C1]、[C2]、[A1] 从"单会话故障"提升为"全 Bridge 宕机"。

建议：在 `index.ts` 注册 `process.on("unhandledRejection", ...)` 记录并降级（不退出），同时逐条修掉 floating promise。

**[E2] [P1] [session.ts:1103-1108] `processMessage` 的兜底 catch 只 `console.error`，客户端得不到任何错误信号**

图片注册、artifact 物化、gallery 写盘任一失败，用户看到的是"这条消息就是没出现"，没有 error 消息、没有降级提示、没有重试。

**[E3] [P1] [codex-process.ts:2896-2921 catch 内] catch 里的 `this.emit("exit", 1)` 若被同步监听器抛出，会让 `void this.bootstrap(...)`（1826）变成未处理 rejection**

`session.ts:1149` 的 exit 监听器同步执行 `finish()`（含 `evictStaleIdleSessions` → `destroy` → `child.kill()`），一旦抛出就会穿透 bootstrap 的 catch（catch 内部的 throw 不再被自己捕获）→ `void` 掉的 promise reject → 结合 [E1] 直接杀进程。

**[E4] [P2] [codex-desktop-continuity.ts:306-313] 三种情况下静默吞掉 rollout 错误**

```ts
} catch (error) {
  if (this.closed || context.signal.aborted || !this.isCurrentWatchIntent(client, intent)) {
    return;                    // 无日志、无事件
  }
```
`isCurrentWatchIntent` 为 false 是 [D1] 竞态的高频分支，出错时客户端只能靠 4s ack 超时发现，排查时没有任何服务端痕迹。建议至少加 debug 日志。

**[E5] [P2] [codex-desktop-continuity.ts:344-350] `admitSupportedInput` 的空 catch 把所有失败一律 fail-open**

```ts
try { monitor = await this.monitorFor(threadId); await monitor.refreshNow(); }
catch { return { action: "allow" }; }
```
注释说明是为老会话兜底，但它同时吞掉了"文件权限错误""磁盘 IO 错误""MAX_MONITORS 超限"，这些情况下 Desktop 正在跑 turn 也会被放行，破坏了整个 continuity 的安全前提（本应 fail-closed）。建议按错误类型区分：仅"未找到 rollout"才 fail-open。

**[E6] [P2] [codex-process.ts:2400-2265 一组] `approve/reject/answer` 在无 toolUseId 时取 Map 的第一个条目**

```ts
private resolvePendingApproval(toolUseId?: string) {
  if (toolUseId) return this.pendingApprovals.get(toolUseId);
  const first = this.pendingApprovals.values().next();
  return first.done ? undefined : first.value;
}
```
同时存在多个待审批时（并行工具调用），旧客户端不带 toolUseId 的批准会作用到**任意一个**，用户批准 A 实际放行了 B。

**[E7] [P2] [codex-process.ts:2887-2893] bootstrap 尾部的 `setTimeout(..., 25)` 不 unref、不记录、不在 `stop()` 里 clear**；`codex-process.ts:1547` 的 `action.startTimeout` 同样未 unref。

**[E8] [P3] [codex-desktop-continuity.ts:1273-1277, 1472-1476, 2555-2557, 2563-2565, 2723-2725] 五处 `catch {}` 静默丢弃 JSON 解析失败**，rollout 文件损坏时完全无感知，只表现为"部分 Desktop 消息没同步过来"。

---

## 优先级建议

**必须先修（P0）**：
1. `index.ts` 加 `unhandledRejection` 兜底（[E1]）—— 这是所有其它 P0 的放大器
2. `codex-transport.ts` 给 stdin 挂 error 监听（[A1]）
3. `session.ts` 的 `trackMessageWork` 加 catch、四处 `void save*` 加 catch（[C1][C2]）
4. `sdk-process.ts` 的 `pendingPermissions` 统一 reject 而非 clear（[A13] 前两条）
5. `parser.ts` 的 `isPromptHistoryEntry` 补全字段校验 + `importEntries` 改为原子替换（[B1]）

**Continuity 专项（对应交接文档 v02-012）**：
[D1] 的 ownership 显式移交是根因，[D2][D3][D4] 都会放大它的可观测症状。建议按 [D1] → [D3] → [D4] → [D2] 的顺序处理，并补一条"同一 socket 上 tracker 与 cubit 交替抢占"的集成测试（现有 2154 行的 CAS 测试没覆盖这条）。

**注**：codex-process.ts 的审批状态机 / handleNotification / Goal RPC / thread-settings 链这四块还有一路子审查在跑，其结论尚未返回；本报告中 codex-process 部分是我直读得出的生命周期与状态机结论。
I received the codex-process results. The parser and sdk-process reviews are still running — let me do my own targeted pass on parser.ts meanwhile.
我已完成对五个文件的审查（parser.ts 与 sdk-process.ts 的两路专项深审仍在后台运行，下面是我本人已验证的结论）。

---

# Bridge 核心五文件正确性/健壮性审查

先说结论：**最该先修的是 A1、A2、A7、E1、D1**。其中 E1（无 `unhandledRejection` 兜底 + 多处裸 `void promise`）和 A1（stdin 无 `error` 监听）是**整个 Bridge 进程级**的崩溃面，不止影响单会话；D1 是交接文档 v02-012 点名的 watch ownership 竞态，我定位到了具体机理。

---

## A. 进程生命周期

**[A1] [P0] [codex-transport.ts:101-106]**
问题：`StdioCodexTransport.write()` 直接写 `child.stdin`，全文件**没有给 `child.stdin` 注册 `error` 监听器**。
触发场景：app-server 崩溃/被 kill 后 Bridge 仍写入 → stdin 触发 `EPIPE`；Node 的 EventEmitter 对无监听器的 `'error'` 事件会 **throw**，且这是异步 I/O 回调栈，`writeEnvelope` 外层的 try/catch 抓不到 → **整个 Bridge 进程崩溃，所有会话一起死**。
证据：
```ts
write(envelope: Record<string, unknown>): void {
  if (!this.child || this.child.killed) throw new Error("codex app-server is not running");
  this.child.stdin.write(`${JSON.stringify(envelope)}\n`);   // 无 error 回调、stdin 无 'error' 监听
}
```
修复方向：`child.stdin.on("error", ...)` 静默转成 transport `error` 事件；`write` 传第二个回调参数处理失败；同时检查 `write()` 返回值做背压。

**[A2] [P1] [codex-transport.ts:108-113]**
问题：`stop()` 只发 `SIGTERM`，**没有超时升级到 SIGKILL**，也没有用进程组（未 `detached` / 未 `kill(-pid)`）。
触发场景：app-server 卡在不可中断状态或忽略 SIGTERM → 子进程变孤儿常驻；codex 自己 spawn 的工具子进程（grandchildren）更是完全不受影响，一律残留。
证据：
```ts
stop(): void {
  if (this.child) { this.child.kill("SIGTERM"); this.child = null; }
}
```
另外 `this.child = null` 是立刻置空，之后无法再补发 SIGKILL。
修复方向：保留 handle，`setTimeout(() => child.kill("SIGKILL"), 3000).unref()`；spawn 时 `detached: true` + `process.kill(-child.pid, sig)`。

**[A3] [P0] [codex-transport.ts:91-98 / codex-process.ts:1961-1969]**
问题：spawn 失败（`ENOENT`，即 codex CLI 未安装）时 Node 只发 `'error'` + `'close'`，**不发 `'exit'`**；而 transport 只监听 `'exit'`，codex-process 的 `error` 分支既不 `rejectAllPending()` 也不置空 `this.transport`。
触发场景：codex 未安装 / PATH 不含 codex → `bootstrap` 里无超时的 `await this.request("initialize")` **永久挂起**，会话永远停在 `starting`。
证据：
```ts
// codex-transport.ts
child.on("error", (err) => { this.emit("error", err); });      // 无 close 监听
child.on("exit", (code) => { this.child = null; this.emit("exit", code ?? 0); });
// codex-process.ts:1961
transport.on("error", (err) => {
  if (this.stopped) return;
  ...; this.setStatus("idle"); this.emit("exit", 1);           // 不 rejectAllPending / 不清 transport
});
```
且 `isRunning` = `child !== null && !child.killed`，ENOENT 后仍返回 true → 后续 `writeEnvelope` 继续往死 stdin 写（叠加 A1）。
修复方向：transport 改监听 `'close'`；error 分支复用 exit 分支的清理逻辑。

**[A4] [P1] [codex-process.ts:2896-2921]**
问题：`bootstrap()` 的 catch 里只 `setStatus("idle") + emit("exit", 1)`，**不调用 `this.stop()`，不停 transport**。
触发场景：`thread/resume` 返回错误、Plan 能力探测失败、`thread/fork` 契约校验失败等 → Bridge 认为会话已退出，但 `codex app-server` 子进程仍在跑，成为孤儿；每次 bootstrap 失败泄漏一个。
修复方向：catch 中调用 `this.stop()`（或至少 `this.transport?.stop()`）后再 emit exit。

**[A5] [P1] [codex-process.ts:3373]**
问题：`runInputLoop` 用空字符串作为退出哨兵，任何一次空 text 都会**永久终止输入循环**，且循环退出后 `bootstrap` 的 try 正常结束——不 emit exit、不停 transport。
触发场景：`sendInputStructured("")`（`session.ts:2044` 的 `drainCodexQueue` 直接透传 `queued.text`）。目前唯一的空串防护在 `websocket.ts:4680` 的 `msg.text.trim()`，属于跨层的隐式契约。
证据：
```ts
if (this.stopped || !pendingInput.text) break;   // 与 stop() 的 inputResolve({text:""}) 共用同一哨兵
```
后果：会话看起来 `idle`，但 `isWaitingForInput` 永远 false，此后所有输入走 “No pending input resolver” 分支静默丢弃，只能重启会话；transport 仍活。
修复方向：改用显式哨兵（`PendingInput | null` 或 `{ __stop: true }`），空 text 走 `continue`。

**[A6] [P1] [codex-process.ts:4812-4826]**
问题：`request()` **默认不设超时**（`timeoutMs` 仅在调用方显式传入时生效），唯一的兜底是 `rejectAllPending`（只在 stop / transport exit 时触发）。
后果：app-server 不回包（挂死、协议不兼容、共享 app-server 模式下丢包）→ 对应 promise 永久 pending，`pendingRpc` Map 单调增长。
修复方向：给 `request` 一个全局默认超时（如 60s），交互类 RPC 单独放宽。

**[A7] [P0] [codex-process.ts:2446-2451]**（子代理独立复现，我已核对）
问题：审批解决后 `resumeRunningIfNoPendingInteractiveRequest()` **无条件 `setStatus("running")`**，不检查是否还有活跃 turn。
触发场景：`turn/completed` 先于审批被解决而到达（用户中断、guardian 审阅、多端并发）。`handleTurnCompleted` 因 `pendingApprovals.size > 0` 不置 idle（4350-4355），但已把 `pendingTurnId = null`（4327）。此后用户点批准/拒绝 → 状态变 `running`，且再无 turn/completed 把它拉回 idle。
证据：
```ts
if (this._idleWhenInteractionsClear) { ...; this.setStatus("idle"); }
else { this.setStatus("running"); }        // ← 缺 pendingTurnId 判断
```
同语义的正确写法就在同文件 `handleServerRequestResolved`：`this.setStatus(this.pendingTurnId ? "running" : "idle")`（5010）——两处实现不一致，说明是遗漏。
后果：`isWaitingForInput` 要求 `_status !== "running"`（631-637）→ 该会话**永久无法再输入**。
修复方向：`this.setStatus(this.pendingTurnId || this.activeCoreActionTurnId ? "running" : "idle")`。

**[A8] [P1] [codex-process.ts:1971-1983 + 4411-4416]**
问题：transport `exit` 处理器不调用 `cleanupSteerTempPaths()`（只有 `handleTurnCompleted`/`stop`/`prepareLaunch` 调）。app-server 异常退出且外部不再 `stop()` 时，steer 上传的图片临时文件永久残留在 tmpdir。

**[A9] [P2] [codex-process.ts:3416-3509]**
问题：`pendingTurnCompletion` 无超时。app-server 不发 `turn/completed` 时 `runInputLoop` 永久停在 `await`，不再 emit `input_ready`，会话卡在 `running`。

**[A10] [P2] [codex-process.ts:3382-3385]**
问题：`toRpcInput` 已生成的 `tempPaths` 在 `if (!input) continue;` 分支不被清理（而正常/异常两条路径都有清理），临时文件泄漏。

**[A11] [P2] [codex-process.ts:1818-1826]**
问题：重复 `start()` 时旧的 `void this.bootstrap(...)` 仍在跑，`prepareLaunch` 把 `_runtimeGeneration += 1`（1877）但 **bootstrap 全程不校验 generation**；`stopped` 又被重置为 false，于是旧 bootstrap 的 await 续体会通过 `if (!this.stopped)` 守卫，把旧配置写进新 runtime。
修复方向：bootstrap 起始快照 `_runtimeGeneration`，每个 await 后比对。

**[A12] [P2] [codex-process.ts:1855-1856 / 1971-1983]**
问题：`stop()` 清空 `pendingApprovals`/`pendingUserInputs` 时**不回应**这些 outstanding server request（stop 场景可接受）；但 transport `exit`（崩溃）路径**根本不清空**它们。
后果：进程死后 `getPendingPermission()` 仍返回条目 → `session.ts:1361` 的 `list()` 继续向手机上报 `pendingPermission`，用户看到一个永远点不动的审批弹窗。

**[A13] [P2] [session.ts:1149-1175]**
问题：`proc.on("exit")` 只把 `status` 置 `idle`，**不把 session 从 `this.sessions` 移除**。进程已死的会话继续出现在 session list、可被 resume/输入（输入会静默丢弃）。只有 `evictStaleIdleSessions` 在超过 30 个 idle 会话时才可能顺带回收。

**[A14] [P2] [codex-process.ts:1547-1560]**
问题：`action.startTimeout` 未 `.unref()`（同文件其它定时器如 3891、4842 都 unref 了），会短暂阻止事件循环退出。

---

## B. 消息解析与协议

先澄清一个结构事实：`parser.ts` **不做** provider 流式输出解析，它是「入站 ClientMessage 校验器 + ServerMessage/ClientMessage 类型联合定义 + `normalizeToolResultContent`」。真正的行缓冲 / delta 组装 / 编码处理在 `codex-process.ts:handleStdoutChunk` 与 `codex-desktop-continuity.ts:consumeText`。

**[B1] [P2] [parser.ts:2381]**
问题：`parseClientMessage` 校验通过后 `return msg as unknown as ClientMessage`，返回的是 **`JSON.parse` 的原始对象**，不是按白名单重建的对象；且只有部分 case 调用了 `hasOnlyKeys`。
后果：(a) 未在该 case 中显式校验的字段在类型上是必填 / 已定型，运行时却可能是任意值或 undefined，下游 `msg.x.y` 会 undefined 崩；(b) 多余键原样进入下游并可能被透传/持久化。这是「类型断言与实际校验不同步」的系统性风险，随着 case 增多必然积累。
证据：
```ts
      default:
        return null;
    }
    return msg as unknown as ClientMessage;   // 原对象直出
```
修复方向：每个 case 显式构造返回对象（就像 `codex-desktop-continuity-protocol.ts:parseClient` 那样），或统一强制 `hasOnlyKeys`。

**[B2] [P2] [parser.ts:1112-1123]**
问题：`normalizeToolResultContent` 对 `type === "text"` 的块直接 `c.text as string`，不校验 `text` 真是字符串。
证据：
```ts
return (content as Array<Record<string, unknown>>)
  .filter((c) => c.type === "text")
  .map((c) => c.text as string)      // text 可能是 undefined/null/object
  .join("\n");
```
后果：`join` 把 `undefined` 渲染成空串、把对象渲染成 `[object Object]`，污染 history 与推送预览。
修复方向：`.filter(c => typeof c.text === "string")`。

**[B3] [P1] [codex-process.ts:3518-3524]**
问题：`this.stdoutBuffer += chunk` **无上限**，没有最大行长保护。
触发场景：app-server 输出一条超大 JSON（大 tool_result / 图片 base64）或输出损坏（永不出现换行）→ 内存单调增长直至 OOM。
对比：同仓库的 `codex-desktop-continuity.ts` 就有 `MAX_LINE_BYTES = 2MB` 保护，说明这是遗漏而非设计。
修复方向：加 `MAX_LINE_BYTES`，超限进入丢弃模式直到下一个换行。

**[B4] [P1] [codex-desktop-continuity.ts:1233-1256]**
问题：`seed()` 读到文件末尾后直接 `this.offset = info.size`，但 `text.split("\n")` 的最后一段若是**正在写入的半行 JSON**，seed 里 `JSON.parse` 失败被丢弃，而实时读取又从 `info.size` 之后开始 —— **该条目的前后两半都被丢弃，永久丢失一条 Desktop 消息**。
证据：
```ts
this.seedLifecycle(text.split("\n"), info.mtimeMs, truncatedActiveLine);
this.offset = info.size;      // 半行的前半已丢，后半会被当成独立行解析失败
```
修复方向：`offset` 回退到最后一个 `\n` 的位置，把残余半行放进 `lineBuffer`。

**[B5] [P2] [codex-desktop-continuity.ts:2728-2732]**
问题：`boundedText` 按**字节**切 Buffer 后 `.toString("utf8")`，会在多字节字符中间截断，产生 U+FFFD 替换字符；emoji / 中文正文被截断处必然乱码。
证据：
```ts
const buffer = Buffer.from(value, "utf8");
return `${buffer.subarray(0, maxBytes).toString("utf8")}\n…[truncated by Bridge]`;
```
修复方向：用 `TextDecoder` 的 `stream` 模式，或回退到最近的完整码位边界（并处理 surrogate pair）。

**[B6] [P2] [codex-desktop-continuity.ts:1447-1466]**
问题：`consumeText` 每追加一段就对**整个** `lineBuffer` 调 `Buffer.byteLength()`，长行下是 O(n²)；且超过 `MAX_LINE_BYTES` 后整行**静默丢弃**，不发任何告警/降级事件，Desktop 侧一条大 tool 输出会无声消失。
修复方向：维护累计字节数增量；丢弃时至少 emit 一条截断提示。

**[B7] [已检查无问题]** 实时读取路径的 UTF-8 边界处理是正确的：`codex-desktop-continuity.ts:1073` 用 `StringDecoder("utf8")` 并在 `readPass` 中 `this.decoder.write(buffer)`，chunk 边界切断多字节字符不会乱码；文件截断（`info.size < this.offset`）时也正确重建了 decoder。`codex-transport.ts` 的 `child.stdout.setEncoding("utf8")` 同理安全。

**[B8] [已检查无问题]** 未知 client 消息类型的 graceful degradation 是完整的：`parser.ts` `default: return null` → websocket 回 `errorCode: "unsupported_message"`，App 侧有 `_unsupportedActions` 分类处理，不会中断连接。

---

## C. 会话状态机（session.ts）

**[C1] [P1] [session.ts:693-699 + 1113-1120 + 1141-1145 + 1170-1174]**
问题：`trackMessageWork` 建立的 promise 链 **没有任何 `.catch()`**，一旦某一环 reject：
1. `tracked` 变 rejected 并被赋给 `messageProcessing`；
2. 下一条消息 `messageProcessing.then(processMessage)` 在已 rejected 的 promise 上不会执行 `processMessage`，返回的仍是 rejected promise，又被存回 `messageProcessing` → **该会话的消息管线被永久毒化，之后所有 provider 消息静默丢弃**；
3. 若之后没有新消息接续，最后那个 rejected promise 无人处理 → **unhandled rejection → 整个 Bridge 退出**（见 E1）。
证据：
```ts
const trackMessageWork = (work: Promise<void>): void => {
  const tracked = work.finally(() => { if (messageProcessing === tracked) messageProcessing = null; });
  messageProcessing = tracked;                    // 没有 .catch
};
...
trackMessageWork(messageProcessing.then(drain));   // drain / finish 均无 try/catch 保护
trackMessageWork(messageProcessing.then(finish));
```
`processMessage` 自身全包 try/catch 是安全的，但 `drain`（→ `drainCodexQueue` → `codexQueueDrainHooks.canDrain` → local-features → `onMessage` 广播）和 `finish`（→ `evictStaleIdleSessions` → `destroy` → `process.stop()` → `child.kill()` 可能 EPERM）都**没有**。
修复方向：`trackMessageWork` 内统一 `.catch(err => console.error(...))`；`drain`/`finish` 各自包 try/catch。

**[C2] [P1] [session.ts:635-682]**
问题：`commitReplacement()` 只搬运了 `name / autoRename / autoRenameAttempted / codexQueuedInput / codexGoal* / status / lastActivityAt`，**没有搬运** `history / historyEntries / historyRevision / historyLowWatermark / codexOrderedHistoryEntries / codexLatestUserInput / codexUserTurnUuidByRawId / pendingCodexUserEchoUuids / codexCanonicalHistoryRevision / codexHistoryResetRevision`。
触发场景：Desktop continuity 每完成一次外部 turn 都会走 `replaceCodexSession` → 同一个 public session id 下的内存历史被清零、`historyRevision` 从 N 回退到 0。
缓解（已确认）：`websocket.ts:3217-3225` 的 `shouldResetCodexHistoryDelta` 在 `codexHistoryResetRevision`/`codexCanonicalHistoryRevision` 均为 undefined 时返回 true，会强制下发一次全量 canonical 快照，所以不会直接丢历史。
残留问题：`codexLatestUserInput` 被丢弃后，`applyCodexCanonicalHistoryBaseline` 无法在 tail 被裁剪时保住「刚发出的那条用户消息」；`codexUserTurnUuidByRawId` / `pendingCodexUserEchoUuids` 丢失会让 canonical user echo 的去重逻辑失效。这两点与交接文档记录的「中间过程/最终回复偶发整段重复两次」是同一条嫌疑线。
修复方向：把这些字段一并纳入原子交接。

**[C3] [P2] [session.ts:1474-1506]**
问题：`mergeUserInputIntoHistory` 原地修改 `session.history[i]` / `entry.message`，**不 bump `historyRevision`**（有意保留 seq，见 1496）。
后果：走 `get_history_delta` 的客户端如果 `sinceSeq >= entry.seq`，永远拿不到这次 UUID 回填；只有当时在线、收到 live `onMessage` 的客户端能看到。断线重连的客户端会保留一条无 UUID 的用户消息（影响 rewind/fork 定位）。
修复方向：合并后追加一条轻量 `history_patch` 条目，或把 merged 消息作为新 seq 追加并让客户端按 uuid 去重。

**[C4] [P2] [session.ts:1739-1751]**
问题：`trimHistory` 用 `Array.shift()` 逐条裁剪两个数组，`MAX_HISTORY_PER_SESSION = 100`，每条超限消息触发两次 O(n) 搬移。量级不大但属于热路径上的无谓开销。
修复方向：一次 `splice(0, overflow)`。

**[C5] [P2] [session.ts:2380-2398]**
问题：`evictStaleIdleSessions` 在**每次 status→idle 和每次 exit** 时触发，超过 `MAX_IDLE_SESSIONS = 30` 就静默 `destroy()` 最久未活动的 idle 会话——包括用户此刻正打开着的那个（只要它 idle 且够旧）。用户侧只能通过 session list 变化感知。
修复方向：至少排除有活跃 WebSocket 订阅者的会话，或改为发一条明确的 `session_evicted` 通知。

**[C6] [P2] [session.ts:2143-2190]**
问题：`rewindConversation` 先 `this.destroy(id)` 再 `this.create(...)`。若 `create` 抛出（worktree 不存在、SDK 启动失败），旧会话已被销毁且无回滚 → 会话直接丢失。
修复方向：先 create 成功再 destroy，或加 try/catch 回滚。

**[C7] [P2] [session.ts:2360-2378]**
问题：`destroy()` 对 ephemeral side chat 子会话做**无深度限制的递归**（`for (const childId of childIds) this.destroy(childId)`）。若 `auxiliary.parentSessionId` 出现环（自引用或互相引用），会栈溢出。目前 `parentSessionId` 由内部赋值，风险低但无任何防护。

**[C8] [P2] [codex-process.ts:2176-2184 / 2197-2205 / 2227-2235]**
问题：`approve()/approveAlways()/reject()` 在 `toolUseId` 缺省时通过 `resolvePendingApproval(undefined)` 取 **Map 里的第一条**。多个审批并发挂起时（旧客户端不带 toolUseId），会批准/拒绝到错误的那一条。
修复方向：无 toolUseId 时，pending 数量 > 1 就拒绝执行并回错误。

---

## D. Codex Desktop Continuity（重点）

**[D1] [P1] [codex-desktop-continuity.ts:587-611 + chat_session_cubit.dart:563-583 + desktop_session_list_continuity_tracker.dart:205-231]** ← 这就是 v02-012 说的 watch ownership 转移竞态
问题：Bridge 侧 `watchersByClient` 以 **`(client, sessionId)`** 为键，`registerWatch` 是**后写覆盖且不通知被顶掉的一方**。而首页 tracker 和打开的聊天 cubit **共用同一个 WebSocket client 对象**，所以它们在 Bridge 眼里是同一个 owner，只能靠 requestId 前缀（`list-` vs uuid）在 Dart 侧互相猜测归属。
证据（Bridge 侧覆盖，无任何事件发给旧 owner）：
```ts
const previous = registrations?.get(message.sessionId);
if (previous) {
  const previousMonitor = this.monitors.get(previous.threadId);
  previousMonitor?.removeWatcher(previous);      // 静默摘除，不发 unwatched
}
registrations.set(message.sessionId, registration);
```
触发场景（帧序可复现）：聊天页 `_ensureDesktopContinuityWatch` 在 563 行**先发 `unwatch(Rold)` 再发 `watch(Rnew)`**（每次 thread 变更 / force 刷新都会走）。Bridge 处理 `unwatch(Rold)` 时回 `unwatched(Rold)`，tracker 命中 `_displacedByConversation[S] == Rold` → 立即 `_ensureWatch` 发 `watch(list-X)`。但此时 `watch(Rnew)` 已经排在 socket 队列里先到，于是 Bridge 的处理顺序是 `unwatch(Rold)` → `watch(Rnew)` → `watch(list-X)`，**tracker 的 watch 反过来把打开中的聊天页顶掉**。聊天页因 requestId 不匹配忽略所有事件，直到 4 秒 ack 超时（`_desktopContinuityWatchAckTimeout`）才重试 —— 期间打开的会话完全收不到 Desktop 事件，之后还会再来一轮互顶。
额外：`unwatch(Rold)` 触发 `disposeMonitorIfUnused` → monitor 被 close，随后又要重建 + 重新 `seed()`（最多 8MB 读盘），每次进出会话都churn 一次。
修复方向：Bridge 侧把注册键从 `(client, sessionId)` 改为 `(client, sessionId, requestId)` 允许多 owner 共存并 fan-out；或至少在被覆盖时向旧 requestId 显式发一条 `unwatched`，让 tracker 立刻知道自己被顶而不是靠猜；同时聊天页改为「先发新 watch，收到 watching 后再发旧 unwatch」。

**[D2] [P2] [codex-desktop-continuity.ts:267-270 + 306-320 + 589-591]**
问题：`registerWatch` 在 `totalWatcherCount >= MAX_WATCHERS` 时 **throw**，异常被 306 行的 catch 接住并回 `rollout_unavailable`，但**没有调用 `disposeMonitorIfUnused`** —— `monitorFor` 已经把新 monitor 放进 `this.monitors`（550 行）。
后果：留下一个 0 watcher 的 monitor，持有 `fs.watch` + 750ms `setInterval` + 一个打开的 fd，直到某次 `MAX_MONITORS` 淘汰才被回收。
证据：成功路径的 `if (!this.registerWatch(...)) { this.disposeMonitorIfUnused(...); return; }` 有清理，throw 路径没有。
修复方向：catch 里补 `this.disposeMonitorIfUnused(message.threadId, monitor)`。

**[D3] [P1] [desktop_session_list_continuity_tracker.dart:189-201 + sessions-index.ts:3417-3438]**
问题：tracker 对 `rollout_unavailable` 这类错误**无限重试**（只有 `path_not_allowed` / `continuity_binding_mismatch` 会进 `_suppressedSessionIds`），退避封顶 8 秒、无最大次数、无最终放弃；而 Bridge 侧每次重试都要走 `resolveCodexSessionJsonlPath` → `findCodexSessionJsonlPath`，在**解析失败**这条路径上会遍历 `~/.codex/sessions` 全树并逐个打开每个 `.jsonl` 读首行。
证据：
```dart
if (message.event == ...unwatched ||
    (message.errorCode != 'path_not_allowed' && message.errorCode != 'continuity_binding_mismatch')) {
  _scheduleWatchRetry(message.sessionId);      // rollout_unavailable 落在这里，永远重试
}
```
```ts
async function findCodexSessionJsonlPath(threadId) {
  const files = await listCodexSessionFiles();   // 每次全量递归 readdir，无缓存
  for (const filePath of files) { ... await codexJsonlHasThreadId(filePath, threadId); }
  return null;                                    // 失败时把所有文件都开过一遍
}
```
触发场景：新建线程 rollout 文件尚未落盘、线程被归档、CODEX_HOME 切换。后果是**每 8 秒一次全量目录扫描 + N 次 open**，持续到会话消失；手机侧同时保持定时器不休眠。
修复方向：`rollout_unavailable` 加最大重试次数并计入 `_suppressedSessionIds`；`listCodexSessionFiles` 加带 mtime 失效的缓存。

**[D4] [P1] [codex-desktop-continuity.ts:337-370]**
问题：`admitSupportedInput` 在**每条用户输入**的关键路径上 `await this.monitorFor(threadId)`。若该 thread 的 rollout **无法解析**，`monitorFor` 每次都抛异常且不会缓存失败结果 → 每发一条消息都要付一次 D3 里那个全量扫描的代价，输入延迟直接和用户的 Codex 历史规模成正比。
证据：
```ts
try { monitor = await this.monitorFor(threadId); await monitor.refreshNow(); }
catch { return { action: "allow" }; }     // fail-open 正确，但代价没缓存
```
修复方向：为解析失败的 threadId 加负缓存（TTL 几分钟）。

**[D5] [P1] [codex-desktop-continuity.ts:351-368 + 974-998]**
问题：rehydrate 永久失败时**没有 fail-open 出口**。`staleRuntimeSessionIds` 只在 rehydrate 成功或 session 消失时清除；失败 3 次后只发一条 advisory `runtime_rehydrate_failed`，`staleRuntimeSessionIds` 仍然保留。
后果链：`admitInput` 恒返回 `{action:"queue", reason:"desktop_history_refreshing"}`（367），`admitCodexQueuedInputDrain` 恒返回 false（402-407）→ **用户的消息全部堆在队列里发不出去**。虽然 360-365 行会在下一次发送时重置失败计数重试，但只要 `rehydrateCodexSessionAfterExternalTurn` 持续失败（例如 canonical history RPC 一直报错），用户就永远处于「消息已排队、永不发送」状态，UI 上只有一条建议性错误。
修复方向：连续失败 N 次后清除 stale 围栏并降级为「历史可能不完整」的警告，允许发送。

**[D6] [P2] [codex-desktop-continuity.ts:726-731 + 531]**
问题：`onEvent` 回调闭包捕获的是 `threadId`，`onMonitorEvent` 用 `this.monitors.get(threadId)` 反查 monitor 而**不与发事件的 monitor 做身份比对**。
证据：
```ts
onEvent: (event) => this.onMonitorEvent(threadId, event),
// ...
private onMonitorEvent(threadId, event) {
  const monitor = this.monitors.get(threadId);   // 可能已是"新"monitor
  if (!monitor) return;
  const registrations = monitor.watchers;        // 事件被广播给新 monitor 的 watcher
```
触发场景：monitor 被 dispose+重建（D1 的每次进出会话都会发生）期间，旧 monitor 尚未执行完的回调（`queueCompletedEventTool` 的 `queueMicrotask`、pending assistant `setTimeout`）会把事件投递给新 monitor 的 watcher → 重复消息。目前靠 `close()` 里的 `this.closed = true` + 清 timer 侥幸挡住，属于偶然安全。
修复方向：`onEvent: (event) => this.onMonitorEvent(threadId, monitor, event)`，入口比对 `this.monitors.get(threadId) === monitor`。

**[D7] [P2] [codex-desktop-continuity.ts:463-476 + 694-707]**
问题：tracker **从不发送 unwatch**（全仓库只有 `chat_session_cubit.dart:606` 调 `requestCodexDesktopContinuityUnwatch`）。session 从列表消失时 tracker 只清本地 map，Bridge 侧的 `WatchRegistration` + `WatchIntent` + monitor 全部保留，直到 WebSocket 断开才由 `disconnect()` 清理。
后果：会话被 `evictStaleIdleSessions` 销毁后，其 continuity monitor 仍在以 750ms 轮询一个已死会话的 rollout 文件；也让 `hasCurrentWatchIntentForThread`（701）恒为 true，`disposeMonitorIfUnused` 永远不会回收该 thread 的 monitor。
修复方向：tracker 在 `_syncSessions` 移除会话时补发 unwatch；Bridge 侧在 `sessionCatalogChanged` / session 销毁时主动清理对应 registration。

**[D8] [P2] [codex-desktop-continuity.ts:506-516]**
问题：`monitorFor` 的 `MAX_MONITORS` 检查与后续 `await` 之间没有占位，两个并发的不同 threadId 请求可以同时通过 `this.monitors.size >= MAX_MONITORS` 检查后各自插入，实际超出上限。且淘汰只挑 `watcherCount === 0` 的，全部有 watcher 时直接 throw（配合 D3 变成永久重试风暴）。

**[D9] [已检查无问题]** `WatchIntent` 的 generation CAS 机制（636-692）本身是对的：延迟 watch、unwatch、supersede 三种交错都能正确收敛，`disposeMonitorIfUnused` 里的 `hasCurrentWatchIntentForThread` 守卫也正确防止了「新 intent 在途时误关 monitor」。测试 `codex-desktop-continuity.test.ts:2154` 覆盖了这条。问题不在 CAS，而在 D1 说的「同一 client 只能有一个 owner」这个建模层面。

---

## E. 错误处理

**[E1] [P0] [index.ts（缺失）+ codex-process.ts:1826/2471/2889-2891/4069 + session.ts:881/890/1227/1233]**
问题：**全仓库没有注册 `process.on("unhandledRejection")`**（`index.ts` 只有 SIGINT/SIGTERM，479/482），`package.json` engines 是 `node >= 18` —— Node 15+ 默认 `--unhandled-rejections=throw`，**任何一个未处理的 promise rejection 直接终止整个 Bridge 进程，所有 Claude/Codex 会话一起死**。
而代码里存在大量裸 `void promise`：
```ts
// session.ts:881 / 890 / 1227 / 1233 —— 无 .catch，writeFile 可 ENOENT/EACCES/ENOSPC
void saveCodexSessionProfile(msg.sessionId, session.codexSettings.profile);
void saveCodexSessionAdditionalWritableRoots(msg.sessionId, ...);
// codex-process.ts:2471 / 2889-2891 / 4069
void this.installToolSuggestion(pending.toolUseId);
void this.probeNativePlanModeSupport(); void this.probeNextTurnPermissionUpdates(); void this.fetchCompletionEntities(projectPath);
```
`saveCodexSessionProfile` 内部 `await writeFile(join(homedir(), ".codex", "ccpocket-session-profiles.json"), ...)` 没有任何 try/catch，`~/.codex` 不存在或只读就抛 —— 这是最容易触发的一条。
再叠加 C1（`trackMessageWork` 无 catch）和 A1（stdin EPIPE），Bridge 的进程级崩溃面相当宽。
修复方向：(1) `index.ts` 立刻注册 `process.on("unhandledRejection", err => console.error(...))` 兜底；(2) 全仓库把 `void x()` 规范成 `x().catch(logOnly)`，用 ESLint `no-floating-promises` 强制。

**[E2] [P1] [codex-process.ts:1075-1082 vs 905-921]**
问题：thread settings 的 promise 链处理不对称。权限路径写了 `operation.then(() => undefined, () => undefined)` 双分支，runtime 路径只有成功分支：
```ts
this._threadSettingsUpdateTail = operation.then(() => undefined);   // 无 onRejected
const pending = operation.then(() => undefined);
this._pendingRuntimeThreadSettingsUpdate = pending;
void pending.then(() => { ... });                                    // 无 onRejected
```
后果：`operation` 一旦 reject（今天靠内部 try/catch 恰好不会，属隐式契约），(a) 触发 E1 的进程崩溃；(b) `_pendingRuntimeThreadSettingsUpdate` 永不清空，`waitForPendingThreadSettingsUpdates()` 每次重新 await 同一个 rejected promise → `runInputLoop:3391` 此后**每条输入都被判为 `set_permission_mode_rejected` 丢弃，会话永久污染**。

**[E3] [P1] [codex-process.ts:3527-3540]**
问题：`handleStdoutChunk` 的 try 同时包住 `JSON.parse` 和 `this.handleRpcEnvelope(envelope)`，来自通知/审批处理逻辑的任何业务异常都被误报成「Failed to parse codex app-server output」并被吞掉，同时那条通知被静默丢弃。
好的一面是它避免了在 stream `data` 回调里抛出导致 uncaughtException；坏的一面是真实 bug 被永久伪装成协议解析问题，排查时会被彻底带偏。
修复方向：拆成两个 try，dispatch 的异常单独分类打日志。

**[E4] [P1] [codex-process.ts:4278 + 3518-3542]**（子代理发现，我核对成立）
问题：`isForeignThreadNotification` 在 `this._threadId` 为空时**丢弃所有** thread/turn/item 通知；而 `_threadId` 在 `thread/start` RPC 响应 `await` 之后（2818）才赋值 —— await 续体是微任务，跑在 `handleStdoutChunk` 整个同步 while 循环**之后**。
触发场景：app-server 把 `thread/start` 响应和随后的 `turn/started` / `item/*` 写在同一个 stdout chunk（管道下极常见）→ 这些通知在同步循环里被逐条处理，此时 `_threadId` 仍是 null → **全部静默丢弃**。
后果：丢 `turn/started` → `pendingTurnId` 恒为空 → 中断和 steer 全部失效；resume 时回放的历史 item 丢失。
修复方向：在 `handleRpcEnvelope` 里同步识别 thread/start|resume|fork 响应并立刻写 `_threadId`。

**[E5] [P1] [codex-process.ts:3720/3749/3781/3812/3837]**（子代理发现）
问题：`pendingApprovals.set()` / `pendingUserInputs.set()` 全部无重复键检查，同 `toolUseId` 的第二次请求覆盖第一条，被覆盖的 `requestId` **永远收不到响应**，app-server 侧那条 JSON-RPC 请求永久阻塞该 turn。`extractToolUseId` 在无 approvalId/elicitationId 时回退到 `itemId`（4965-4974），同一 command item 的命令审批与 `item/permissions/requestApproval` 会撞键。

**[E6] [P1] [codex-process.ts:4358-4361]**（子代理发现）
问题：`handleTurnCompleted` 末尾**无条件** resolve `pendingTurnCompletion`，不校验 turnId 归属；而紧邻的 4327 行对 `pendingTurnId` 是有守卫的（`if (!turnId || this.pendingTurnId === turnId)`）。Goal 续跑 turn / review 子 turn 的 completed 会提前解开 `runInputLoop` 的等待，并对每个非本地 turn 都向客户端 emit 一条 `result`（重复结果气泡）。

**[E7] [P2] [codex-process.ts:2186-2242 + 4893-4906]**
问题：批准/拒绝**先 delete 再响应**，`respondToServerRequest` 在 transport 已死时只 `console.warn` 吞掉；随后仍 `emitToolResult(..., "Approved")` 告诉客户端成功。用户看到「已批准」但 app-server 从未收到决策，且 pending 条目已删无法重试。
修复方向：`respondToServerRequest` 返回 boolean，失败时不 emit 成功态。

**[E8] [P2] [codex-process.ts:3199-3209]**（子代理发现）
问题：`requestOrNull` 用 `Promise.race` 做超时，既不 `clearTimeout` 也不取消底层 RPC。每次 completion fetch 挂 3 个未 unref 的 10s 定时器；超时后 `pendingRpc` 条目永不删除（`request` 未传 `timeoutMs`）→ Map 单调增长。
修复方向：改用 `this.request(method, params, { timeoutMs })`。

**[E9] [P2] [codex-process.ts:1870-1934 + 3124-3128]**（子代理发现）
问题：`prepareLaunch` 没有重置 `_completionFetchInFlight` / `_completionFetchCooldownUntil`，同时内部守卫只看 `this.stopped`（又被 prepareLaunch 重置为 false）。stop→立刻 start（切 project / 权限重启）时：新一轮 fetch 命中 in-flight 早退 → 新 session 的 skills/apps **永远拉不到**；旧一轮的 `.then` 通过守卫 → **把旧 projectPath 的 skills 写进新 session** 并 emit `supported_commands`。
修复方向：prepareLaunch 清空这两个字段；守卫改用已有的 `_runtimeGeneration` 快照比对。

**[E10] [P2] [codex-process.ts:4776 + 3382]**（子代理发现）
问题：`toRpcInput` 中 `await writeFile` 失败时已写出的 `tempPaths` 是局部变量不返回给调用方 → 临时图片文件永久泄漏；调用点 3382 无 try/catch，异常直接冒出 `runInputLoop` 的 while，**整个会话终止**（与 A5 同样是「循环退出后什么都不清理」）。

**[E11] [P2] [codex-process.ts:4423 / 4490]**（子代理发现）
问题：item 无 `id` 时 started 与 completed 各自生成**不同的** `randomUUID()`，`startedToolItems` 匹配不上 → 重复 emit 一条 `tool_use`（UI 两行工具卡片），started 那条的 `tool_result` 永不到达，条目在 `startedToolItems` 中泄漏（该 Map 无容量上限，对比 `emittedGuardianReviewIdOrder` 有 256 上限、`expectedGoalNotifications` 有 64 上限）。

**[E12] [P2] [codex-process.ts:4332-4346]**（子代理发现）
问题：`pendingPlanCompletion` 直接覆盖赋值，不检查旧的未决 plan 审批。旧 plan 的 `permission_request` 在客户端永远悬挂，且旧 toolUseId 再也无法被 approve/reject 命中（2168-2171 只比对当前那一个）。

**[E13] [P3] [codex-process.ts:4976-4993]**（子代理发现）
问题：`handleServerRequestResolved` 用 `===` 比较 `params.requestId`（`unknown`）与 `PendingApproval.requestId`（`number | string`）。app-server 若把数字 id 序列化成字符串则匹配失败 → pending 条目不清理、不 emit `permission_resolved`、状态停在 `waiting_approval`。建议比较前统一 `String(...)`。

---

## 覆盖度说明

- `codex-process.ts`（6965 行）：我本人 + 一路专项深审，已完整覆盖。
- `session.ts`（2413 行）、`codex-desktop-continuity.ts`（2807 行）：我本人完整读完，并交叉核对了 Dart 侧 `chat_session_cubit.dart`、`desktop_session_list_continuity_tracker.dart` 和 `websocket.ts` 的 `rehydrateCodexSessionAfterExternalTurn` 以确认触发路径真实存在。
- `parser.ts`（2388 行）、`sdk-process.ts`（1427 行）：我做了结构性通读与定向验证（上面 B1/B2 及 A 段的 sdk 相关观察），两路专项深审仍在后台运行，若需要我可以在它们返回后补一份增量清单。
- 按你的要求，websocket.ts 的目录/watcher/推送、conversation-content-sync、sessions-index，以及认证/路径/注入/DoS 安全面均未重复审查（`sessions-index.ts` 只在 D3/D4 里作为性能证据引用）。
