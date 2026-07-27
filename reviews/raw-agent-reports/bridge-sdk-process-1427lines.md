I'll read the file completely in chunks, then check the test file and callers.
Now let me check the consumer (session.ts) and the test file.
全部 1427 行已读完，并核对了 `sdk-process.test.ts`、调用方 `session.ts` / `websocket.ts`，以及 `@anthropic-ai/claude-agent-sdk` 的 `Query.close()` 与 `can_use_tool` 控制请求的实现（`sdk.mjs:62`），用于确认权限 Promise 未 resolve 的真实后果。

审查结果（未修改任何文件）：

**[1] [P0] [sdk-process.ts:825] `interrupt()` 清空 pendingPermissions 但不 resolve，SDK 控制请求永久挂起**
触发：UI 点“停止/中断”（`websocket.ts:7690` → `session.process.interrupt()`）时 status 恰为 `waiting_approval`（有未决权限请求）。
证据：
```ts
this.queryInstance.interrupt().catch(...);
this.pendingPermissions.clear();   // 只删 Map，从不调用 pending.resolve()
```
关键点：唯一的兜底是 `waitForPermission` 的 abort 监听，但它被 `if (this.pendingPermissions.has(toolUseId))`（:1364）门控——条目已被 clear，所以 abort 到来时也不会 resolve。SDK 侧 `processControlRequest` 一直 `await this.canUseTool(...)`，既不写回响应，`finally { this.cancelControllers.delete(request_id) }` 也永不执行（`sdk.mjs:62`）→ CLI 端该工具调用永久阻塞 + SDK 内部 Map 泄漏。
建议：clear 之前统一遍历 resolve 成 `{behavior:"deny", message:"interrupted"}`；abort 监听改为无条件 resolve（幂等即可，Promise 二次 resolve 无害）。

**[2] [P0] [sdk-process.ts:1388] `updateStatusFromMessage` 的 `result` 分支同样只 clear 不 resolve**
触发：turn 因超时/预算/中断提前产出 `result` 时仍有 pending 权限；此后用户点“批准”会走 `approve()` 的 “no pending” 早退（:934），两端都永远等不到结果。
证据：`case "result": this.pendingPermissions.clear(); this.setStatus("idle");`
建议：抽出 `private rejectAllPending(reason)`，在 :665 / :804 / :825 / :1388 四处统一调用。

**[3] [P1] [sdk-process.ts:804, 665] `stop()` / `start()` 同样 clear 不 resolve**
触发：stop 或重启时存在未决权限。危害小于 [1]（`close()` 会强杀 CLI 子进程），但 Promise、`pending.input`（可能含大 payload）与 SDK 的 `cancelControllers` 条目仍被泄漏，且 `start()` 重启场景下 query 未关闭。
证据：`stop()` 中 `this.queryInstance.close(); ... this.pendingPermissions.clear();`
建议：同 [2]。

**[4] [P1] [sdk-process.ts:777-786] `processMessages()` 出错路径不复位 `queryInstance`，`isRunning` 永久为 true，Bridge 继续把输入投给已死进程**
触发：SDK 迭代器抛错（CLI 崩溃/EPIPE 等）且 `stopped === false`。
证据：
```ts
this.processMessages().catch((err) => {
  if (this.stopped) return;
  ... this.setStatus("idle"); this.emit("exit", 1);   // 没有 this.queryInstance = null
});
```
`get isRunning() { return this.queryInstance !== null; }`（:643）→ `websocket.ts:2501`、`websocket.ts:10819`（`if (process.isRunning) return process;`）会复用这个死实例；后续 `dispatchInput` 因 `userMessageResolve === null` 只会无限入队，用户看到“已发送”但永远无响应。
建议：catch 中 `this.queryInstance = null`，并与正常结束路径共用一个 `finalize(exitCode)`。

**[5] [P1] [sdk-process.ts:777-786] 崩溃退出不 emit `session_end`，会话名回写被跳过**
触发：同 [4]。正常结束（:1303）和 `stop()`（:812）都会 `emitSessionEnd()`，唯独错误分支没有。
证据：catch 中只有 `emitMessage(error)` + `setStatus("idle")` + `emit("exit", 1)`。
影响：`session.ts:1181` 的 `proc.on("session_end", ...)`（CLI flush 后重写 session 名）不会执行，崩溃后自定义会话名丢失。
建议：错误路径也调用 `this.emitSessionEnd()`（已有 `sessionEndEmitted` 幂等保护）。

**[6] [P1] [sdk-process.ts:1216-1307 / 662] 重启竞态：旧 `processMessages` 会把新 query 置空并伪造 exit（`stopped` 被 start() 重置，TOCTOU）**
触发：`start()` 内建重启语义（:648 `if (this.queryInstance) this.stop();`），stop 后 :662 立刻 `this.stopped = false`，而旧循环仍挂在旧迭代器上。
证据：
```ts
for await (const message of this.queryInstance) { if (this.stopped) break; ... }
this.queryInstance = null;      // :1299 —— 此时可能已是新 query
this.emitSessionEnd(); this.setStatus("idle"); this.emit("exit", 0);   // :1303-1306
```
旧迭代器结束时 `stopped` 已被重置为 false → break 不生效，直接走到 :1299 把**新**的 `queryInstance` 置 null 并对新会话发 exit 0；若旧迭代器是抛错结束，则命中 [4] 的 catch（`stopped` 亦为 false）→ 给新会话推送 `SDK error:` 并 `emit("exit", 1)`。
说明：当前 `session.ts:1245` 每个会话 new 一个实例、只 start 一次，属于潜在但 API 已暴露的路径。
建议：引入 `runGeneration` 序号，循环与 catch 都用 `gen !== this.runGeneration` 判定过期；或用局部 `const q = this.queryInstance`，仅当 `this.queryInstance === q` 时才置 null / 发事件。

**[7] [P1] [sdk-process.ts:648-650, 686-703] `start()` 在 auth 异步窗口内无重入保护，二次 start 会泄漏第一个 query（孤儿 CLI 子进程）**
触发：auth 预检未完成（`queryInstance` 仍为 null）时再次调用 `start()`。
证据：
```ts
start(...) { if (this.queryInstance) { this.stop(); } ... this.startAfterAuthCheck(...); }
// queryInstance 直到 :733 才被赋值
```
两次 `startAfterAuthCheck` 都会走到 `this.queryInstance = query({...})`（:733），第一个实例引用被覆盖、`close()` 永不调用 → CLI 子进程与 stdio 泄漏，且两个 `processMessages()` 循环同时向同一 EventEmitter 推消息。
建议：加 `starting` 布尔/generation 门闩，在 `start()` 入口即视为“已占用”，或在 :733 赋值前检查 generation 是否过期并立即 `close()` 掉旧的。

**[8] [P1] [sdk-process.ts:838-848, 662-678] 停止后仍接受输入，且 `start()` 不清空 `pendingInputQueue` → 旧会话的残留输入被注入新会话**
触发：进程已 stop / auth 失败后客户端继续发消息；或 auth 失败时 `initialInput` 残留。
证据：
```ts
if (mustQueue || !this.userMessageResolve) {
  this.pendingInputQueue.push({ text });   // 无 this.stopped / isRunning 守卫
  return { queued: true, shouldInterrupt };
}
```
`stop()` 只在当次清队（:798），此后再入队无人消费；而 `start()`（:662-678）只 push `initialInput`，从不重置队列 → 下次启动时旧文本作为首个 user turn 发出。auth 失败路径（:691-701）更不设 `stopped=true`，队列里的 `initialInput` 一直留存。
建议：`dispatchInput*` 入口判 `this.stopped || !this.queryInstance` 返回失败让上层报错；`start()` 中先 `this.pendingInputQueue = []` 再 push `initialInput`。

**[9] [P2] [sdk-process.ts:1363-1368] abort 监听从不 `removeEventListener`，且被 Map 成员检查门控**
证据：
```ts
signal.addEventListener("abort", () => {
  if (this.pendingPermissions.has(toolUseId)) { ...resolve(deny) }
}, { once: true });
```
正常 approve/reject 后监听仍挂在该请求的 AbortSignal 上，闭包持有 `this` 与 resolve；SDK 侧该 controller 在 `finally` 里从 `cancelControllers` 删除后才可回收，正常路径可回收，但配合 [1][2] 的未 resolve 场景会长期驻留。
建议：把 handler 提取为具名函数，在 resolve 后 `signal.removeEventListener("abort", handler)`；同时去掉 `has()` 门控改为幂等 resolve。

**[10] [P2] [sdk-process.ts:805, 1208-1213] `stop()` 直接把 `userMessageResolve` 置 null，用户消息生成器永久挂起在未 settle 的 Promise 上**
证据：
```ts
// stop(): this.userMessageResolve = null;
const msg = await new Promise<SDKUserMsg>((resolve) => { this.userMessageResolve = resolve; });
if (this.stopped) break;
```
该 Promise 永不 settle → 生成器帧、`AsyncGenerator.return()` 的完成、以及闭包持有的 `this` 都无法释放（`Query.close()` 是同步 void，不会因此卡住，故非 P0）。
建议：stop 时保存旧 resolver 并用哨兵值 resolve（随后 `if (this.stopped) break` 生效），或改用 AbortController 驱动的等待。

**[11] [P2] [sdk-process.ts:1113-1123] `fetchSupportedCommands` 的 10s 定时器从不 clearTimeout；结果只按 `stopped` 判活，重启后会串会话**
证据：
```ts
const timeoutPromise = new Promise<null>((resolve) => { setTimeout(() => resolve(null), TIMEOUT_MS); });
Promise.race([this.queryInstance.supportedCommands(), timeoutPromise]).then((result) => { if (this.stopped || !result) return; ... })
```
即使 supportedCommands 立刻返回，定时器仍存活 10s（未 `unref()`），持有闭包并可阻止事件循环退出；重启后 `stopped` 已被重置为 false，旧 query 的迟到结果会以 `supported_commands` 广播给新会话。
建议：race 结束后 `clearTimeout`（或 `.unref()`），并用 [6] 的 generation 判活。

**[12] [P2] [sdk-process.ts:118-164] `listAvailableClaudeModels`：`supportedModels()` 无超时 + idle 生成器永挂 + `void drain` 空操作**
证据：
```ts
async function* createIdleUserMessageStream() { await new Promise<never>(() => {}); }   // :118-120
try { const models = await queryInstance.supportedModels(); ... }
finally { queryInstance.close(); void drain; }   // :160-163
```
`websocket.ts:10670` 直接 `await listAvailableClaudeModels(projectPath)`，若 CLI 不应答该调用会永久挂起（无 timeout、无 AbortController）；`void drain;` 既不 await 也不取消，drain 循环可能在函数返回后继续跑；idle 生成器的 Promise 永不 settle。
建议：给 `supportedModels()` 加 `Promise.race` 超时并在 finally 里 `await drain.catch(()=>{})`；idle 流改成可被 close 唤醒的形式。

**[13] [P2] [sdk-process.ts:1298-1306] 循环退出后无条件 `emit("exit", 0)`，包括 `stopped` 导致的 break 和 CLI 异常退出**
证据：`this.queryInstance = null; this.emitSessionEnd(); this.setStatus("idle"); this.emit("exit", 0);`
主动 `stop()` 之后仍会异步补发一次 exit 0；且 SDK 正常结束迭代但 CLI 实际非零退出时也报 0，调用方无法区分正常结束/崩溃（`session.ts:1149` 的 exit 处理对两者一视同仁）。
建议：区分 `stopped` break 与自然结束；透传 SDK/CLI 的真实退出码。

**[14] [P2] [sdk-process.ts:1313-1351] `handleCanUseTool` / `waitForPermission` 无 `stopped` 守卫**
证据：`waitForPermission` 一进来就 `emitMessage({type:"permission_request"...})` + `this.setStatus("waiting_approval")`。
触发：stop() 之后仍在飞行中的 can_use_tool 控制请求会把状态从 `idle` 拉回 `waiting_approval`，客户端弹出一个永远无法被消费的审批框（对应的 pending 又会被后续 clear 丢弃）。
建议：入口处 `if (this.stopped) return { behavior:"deny", ... }`。

**[15] [P3] [sdk-process.ts:626, 652] `_projectPath` 只写不读（死字段）**
证据：`private _projectPath: string | null = null;` / `this._projectPath = projectPath;`，全仓库其余 `_projectPath` 引用均属 `codex-process.ts`。
建议：删除，或按 codex-process 的用法真正利用它。

**[16] [P3] [sdk-process.ts:1095-1101] `listAvailableModels()` 无 try/catch，与同类 `rewindFiles()`(:1083-1093) 的错误处理风格不一致，异常直接抛给 WS 处理器。**

**[17] [P3] [sdk-process.ts:943, 982, 1011] `this.pendingPermissions.delete(id!)` 的非空断言冗余**（`pending` 已由 `id ? ... : undefined` 保证 `id` 存在），建议改成先窄化 `const id = ...; if (!id) return;`。

补充说明（非问题）：`stop()` 未做 SIGTERM→超时→SIGKILL 升级，但这是 SDK `Query.close()` 的职责——其文档明确 “forcefully ends the query, cleaning up all resources including … the CLI subprocess”，并内建 stdin EOF + ~2s 优雅期后 kill，因此本文件层面无需自行升级信号。测试文件 `sdk-process.test.ts` 目前只覆盖纯函数与 `setPermissionMode`/`approveAlways`/`answer`/输入分发；`start()` 在测试环境因缺 `ANTHROPIC_API_KEY` 直接走 auth 失败分支，上述 [1]-[8] 的生命周期与并发路径**完全没有测试覆盖**。
