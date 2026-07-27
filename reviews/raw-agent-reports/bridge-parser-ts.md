I'll start by reading the file in chunks.
Now let me check the test file and downstream usage to verify real impact.
已读完全部 2388 行（分 4 块），并交叉验证了 `parser.test.ts`、唯一的运行时调用方 `websocket.ts:3748`、`sdk-process.ts:476`，以及 `prompt-history-store.ts` / `git-operations.ts` / `image-store.ts` 等下游。关键结论用 `node` 跑 `dist/parser.js` 做了实证（下面凡标"实测"的都跑过）。

先说文件定位：**parser.ts 里只有两个运行时函数**——`normalizeToolResultContent`（1112-1122）和 `parseClientMessage`（1126-2388），其余 1100 行全是类型声明。审查重点 3/4/5（流式 delta 组装、行缓冲、UTF-8 chunk 边界）在本文件里**不存在实现**，相关代码在 `websocket.ts`（delta 批处理）和 `codex-process.ts`（行缓冲），我在最后单列了顺带发现的证据。

---

## 发现

**[1] [P0] [parser.ts:1143-1170 + 2186-2196] `isPromptHistoryEntry` 漏判导致 prompt 历史被整体清空（数据损坏）**
触发场景：客户端发 `{"type":"import_prompt_history_v1","clientId":"c","entries":[{"text":"hi","clientStats":"x"}]}`。
证据：该守卫只校验 `text/projectPath/id/useCount/totalUseCount/isFavorite` 六个字段，而 `PromptHistoryImportEntry` 还有 `createdAt/lastUsedAt/updatedAt/favoriteUpdatedAt/deletedAt/commandKind/clientStats/sessionStats` 八个字段完全没校验：
```ts
if (typeof entry.text !== "string") return false;
...
if (entry.isFavorite !== undefined && typeof entry.isFavorite !== "boolean") return false;
return true;   // clientStats / sessionStats / *At 全部放行
```
实测该消息通过校验。下游 `prompt-history-store.ts:279` 的 `importEntries` 是**先清空再遍历**：`this.data.entries = []` → 循环 → `incrementClientStat` 执行 `entry.clientStats[clientId] = {...}`（store:353）。当 `clientStats` 是字符串/数字时，ESM 严格模式抛 `TypeError: Cannot create property 'c1' on string 'x'`（实测），异常在 `saveBumped()` 之前抛出 → 内存中全部历史已被清空且未恢复，下一次 `record_prompt_history` 的 saveBumped 会把空集合写盘。websocket.ts:9165 的 try/catch 只把错误回给客户端，不回滚。
另外 `updatedAt: 12345`（数字）也能通过，进入 `maxIso` 的 `left >= right` 字符串比较后被当成"更大"直接持久化（实测 `maxIso("2020-01-01T...", 99999) === 99999`），污染类型为 `string` 的持久字段。
修复方向：`isPromptHistoryEntry` 补齐全部字段的类型校验（日期字段必须是 string 且限长、`clientStats`/`sessionStats` 必须是纯对象、`commandKind` 必须在枚举内），并给 `entries` 加条数上限；同时建议 `importEntries` 改为"构建新数组成功后再整体替换"。

**[2] [P1] [parser.ts:1117] `normalizeToolResultContent` 对数组内 `null` 元素直接崩溃，且会打断整条 SDK 消息流**
触发场景：Claude SDK 的 `tool_result.content` 数组里出现 `null`（JSON 合法）。
证据：
```ts
return (content as Array<Record<string, unknown>>)
  .filter((c) => c.type === "text")      // c 可能是 null → TypeError
  .map((c) => c.text as string)
```
实测 `normalizeToolResultContent([null, {type:"text",text:"a"}])` 抛 `Cannot read properties of null (reading 'type')`。调用点 `sdk-process.ts:476` 位于 `processMessages()` 的 `for await` 循环内，**循环内没有 per-message try/catch**；异常会一路冒泡到 `sdk-process.ts:777` 的 `.catch`，结果是整个 session 的消息流终止（后续 assistant/result 全部丢失），客户端只收到一条泛化的 `SDK error`。
顺带：`.map((c) => c.text as string)` 的 `as string` 是空断言——`{type:"text", text:{a:1}}` 会产出 `"[object Object]"`（实测）。
修复方向：`.filter((c) => c && typeof c === "object" && (c as any).type === "text")`，并且 `.map` 改为 `typeof c.text === "string" ? c.text : ""`；同时给 `processMessages` 的循环体加 per-message try/catch，单条坏消息不应终止整条流。

**[3] [P1] [parser.ts:1410-1451、1573-1644 等] 所有 `sessionId` 只判 `typeof === "string"`，空字符串放行 → 操作被静默路由到"另一个 session"**
触发场景：客户端字段未初始化，发 `{"type":"update_queued_input","sessionId":"","itemId":"i","text":"t"}`（实测通过校验）。
证据：parser 侧
```ts
case "update_queued_input":
  if (typeof msg.sessionId !== "string" || ...) return null;   // "" 通过
```
下游 `websocket.ts:9595`
```ts
private resolveSession(sessionId: string | undefined) {
  if (sessionId) return this.sessionManager.get(sessionId);   // "" 落到 else
  return this.getFirstSession();                              // 取列表最后一个 session
}
```
受影响的是**所有把 sessionId 声明为必填**的消息：`update_queued_input`(ws:4674)、`cancel_queued_input`(4705)、`steer_queued_input`(4727)、`get_goal`(5793)、`set_goal`(5833)、`clear_goal`(5899)。例如 `update_queued_input` 会改掉别的 session 的排队输入（ws:5805 `updateCodexQueuedInput(session.id, ...)`），`set_goal` 会把 Goal 写到别的 session。不会报错，静默错投。
修复方向：所有必填 id 统一走 `isNonEmptyString(v, maxLen)` 助手（文件里 `get_history_page`/`resolve_artifact` 已经这么做了，只是没有推广）；`resolveSession` 也应区分"未提供"与"提供了空串"。

**[4] [P1] [parser.ts:2380-2381 + websocket.ts:3748-3767] 校验失败与"未知类型"退化路径合并，带 requestId 的请求会永久挂起**
触发场景：`{"type":"resolve_artifact","requestId":"r1", ..., "messageId":"<513 字符>"}` → parser 因长度超限返回 `null`。
证据：parser 的 `default: return null` 与所有字段校验失败共用同一个 `null` 返回；websocket 侧：
```ts
if (!msg) {
  let rawType; try { rawType = (JSON.parse(raw) as ...)?.type as string; } catch {}
  this.send(ws, { type: "error", errorCode: "unsupported_message", message: rawType ?? "unknown" });
```
问题有两个：(a) 一个**已知类型但载荷非法**的消息被报成 `unsupported_message`，客户端会误判为"Bridge 版本太旧需升级"；(b) 响应里**不带 requestId**，而 `resolve_artifact` / `read_file` / `read_artifact_source` / `get_history_page` / `get_history_tool_details` / `archive_session` 系列都是 requestId 关联的请求-响应，客户端的 pending future 收不到任何相关响应，只能等超时。未知类型本身是 graceful 的（不 throw、不中断连接），这点没问题。
修复方向：`parseClientMessage` 改为返回 `{ok:true,msg} | {ok:false,reason:"unknown_type"|"invalid_payload", type, requestId?}`，让 websocket 能回 `errorCode:"invalid_message"` 并回填 requestId。

**[5] [P1] [parser.ts:1242-1361] `start` 分支有 7 个已声明字段完全不校验，其中 `sessionId` 会绕过 `resume_session` 的校验**
触发场景：`{"type":"start","projectPath":"/a","provider":"codex","sessionId":{"a":1}}`（实测通过）。
证据：`start` 分支校验了 projectPath/model/effort/maxTurns/... 却完全没有 `sessionId`、`continue`、`sandboxMode`、`useWorktree`、`worktreeBranch`、`existingWorktreePath`、`provider` 的校验。而 websocket.ts:3933 把它原样转发：
```ts
if (provider === "codex" && msg.sessionId) {
  await this.handleClientMessage({ type: "resume_session", sessionId: msg.sessionId, ... }, ws);
```
这是**直接调 handleClientMessage、绕过 parseClientMessage** 的路径，于是 `resume_session` 自己的 `typeof sessionId !== "string"` 校验形同虚设，非字符串 sessionId 进入整条 resume 链路（模板字符串变成 `[object Object]`、`resumeOperationKey` 生成脏 key）。
同理 `worktreeBranch` 为对象时会在 `worktree.ts:125` 的 `branch.replace(/\//g,"-")` 抛 TypeError（被 ws:3970 的 try 兜住，退化为 start 失败）。
修复方向：`start` 分支补齐这 7 个字段的校验（`worktreeBranch` 还应限长并拒绝以 `-` 开头，因为它会作为 `execFileSync("git",["rev-parse","--verify",branchName])` 的参数）。

**[6] [P2] [parser.ts:1669-1671] `rename_session` 只校验 sessionId，`name` 任意类型且无长度上限，会污染持久化存储并广播给所有客户端**
触发场景：`{"type":"rename_session","sessionId":"s","name":{"evil":1}}`（实测通过）。
证据：parser 只有 `if (typeof msg.sessionId !== "string") return null;`；websocket.ts:9192 `const name = (msg.name as string | null) || null;`（对象是 truthy，直接透传），随后写入 session 存储并 `this.send(ws, {type:"rename_result", sessionId, name, success:true})`——而 `rename_result.name` 的协议类型是 `string | null`。对比 `archive_session`（parser.ts:2327-2339）对 name 限了 1024 字符，这里毫无限制，10MB 的名字会被持久化并出现在每次 session_list 广播里。
修复方向：`name` 必须 `undefined | null | string` 且限长（与 archive_session 的 1024 对齐）。

**[7] [P2] [parser.ts:1408] `input` 的旧版单图字段校验方向反了，`imageBase64` 类型不校验**
证据：
```ts
// Legacy: imageBase64 requires mimeType
if (msg.imageBase64 && typeof msg.mimeType !== "string") return null;
```
只校验了 `mimeType`，`imageBase64` 本身是什么类型完全不管。实测 `{"type":"input","text":"x","imageBase64":12345,"mimeType":"image/png"}` 通过，websocket.ts:4310-4312 会构造 `{base64: 12345, mimeType:"image/png"}`，违反声明的 `base64: string`。目前靠 `image-store.ts:148` 的 try/catch 兜住（`createHash().update(12345)` 抛异常 → 返回 null），属于"运气好没崩"。同分支的 `imageId` 和 `skill` 也未校验：`skill: 5` 通过后在 ws:4280 变成 `codexSkills = [5]`，后续读 `.name/.path` 得到 undefined。注意同一分支里 `images`/`skills`/`mentions` 三个数组都做了逐元素校验，唯独单数形式的旧字段漏了。
修复方向：`imageBase64`/`imageId`/`mimeType` 校验成 string；`skill` 复用 `skills` 的元素校验。

**[8] [P2] [parser.ts:2201-2218、2271-2274] git 系列消息的 `files` 数组元素类型不校验，`git_unstage.files` 更是完全不校验**
证据：
```ts
case "git_stage":
  if (!Array.isArray(msg.files) && !Array.isArray(msg.hunks)) return null;   // 元素不校验
  ...
case "git_unstage":
  if (typeof msg.projectPath !== "string") return null;   // files 一行校验都没有
```
实测 `{"type":"git_stage","projectPath":"/a","files":[1,{}]}` 和 `{"type":"git_unstage","projectPath":"/a","files":"abc"}` 均通过。下游 `git-operations.ts:213` 是 `execFileSync("git",["reset","HEAD","--", ...files])`：非字符串元素 → Node 抛 `ERR_INVALID_ARG_TYPE`（被 ws:8330 的 try 兜住，退化为 error 响应，不崩）；`files` 是字符串 `"abc"` 时会被展开成三个字符参数 `a b c`，语义完全错误但静默"成功"。注意 `hunks` 的元素校验是做了的（2206-2213），`files` 漏了，属于同分支内不一致。
修复方向：所有 `files: string[]` 统一做 `every(v => typeof v === "string" && v.length>0)`，并加条数/长度上限。

**[9] [P2] [parser.ts:1256/1314/1320/1327/1334/1341/1351/1615/1860/2172 等 ~20 处] `String(msg.x)` 强制转换绕开枚举校验，单元素数组可冒充合法枚举值**
证据（典型形式）：
```ts
if (msg.permissionMode !== undefined &&
    !["default","auto","acceptEdits","bypassPermissions","plan"].includes(String(msg.permissionMode)))
  return null;
```
实测 `{"type":"start","projectPath":"/a","permissionMode":["plan"]}`、`effort:["max"]`、`{"type":"mutate_prompt_history","action":["delete"]}` 全部通过校验（`String(["plan"]) === "plan"`）。下游一律用 `=== "plan"` 严格比较 → 全部落空，行为退化为"该字段没传"，是静默的错误配置（例如 `permissionMode` 静默退回 default）。对照 `set_permission_mode`（1499-1506）用的是 `typeof msg.mode !== "string" || !includes(msg.mode)`，写法是对的，说明这是遗漏而非有意。
修复方向：统一改成先 `typeof === "string"` 再 `includes(msg.x)`，去掉所有 `String()` 包装。

**[10] [P2] [parser.ts:2099-2100、2093] 数值字段只判 `typeof === "number"`，`Infinity` 可通过（JSON 可表达）**
证据：`if (msg.traceLimit !== undefined && typeof msg.traceLimit !== "number") return null;`
`JSON.parse('{"traceLimit":1e999}')` 得到 `Infinity`，实测通过校验（序列化回来是 `null`）。`take_screenshot.windowId`（2093）同样只判 `typeof === "number"`，允许 `Infinity`/负数/小数。对比同文件 `maxBudgetUsd`（1266-1270）正确使用了 `Number.isFinite`，`maxTurns` 用了 `Number.isInteger`（`Infinity` 会被挡）。
修复方向：`traceLimit` 用 `Number.isInteger` + 上下界；`windowId` 用 `Number.isSafeInteger` + `>= 0`。

**[11] [P3] [parser.ts:2384] 结尾 `return msg as unknown as ClientMessage` 是双重断言，未声明字段全部透传**
证据：`return msg as unknown as ClientMessage;`。只有 `resolve_artifact`/`resolve_session_link`/`read_file`/`read_artifact_source`/`git_commit`/`git_push`/`git_branches` 这 7 种用了 `hasOnlyKeys` 做白名单，其余 60+ 种消息的任意额外字段都会原样进入 handler 和 recording-store（`recording-store.ts` 会把 ClientMessage 落盘）。这是"校验通过 ≠ 对象形状符合类型"的根源，上面 [5][6][7] 都是它的具体表现。
修复方向：长期看应该迁到 schema 驱动校验（zod/valibot）并统一 strip 未知字段；短期至少把 `hasOnlyKeys` 推广到所有带持久化副作用的消息。

**[12] [P3] [parser.ts:1126-1128] `parseClientMessage` 对输入长度无任何限制**
证据：`const msg = JSON.parse(data) as Record<string, unknown>;`，入口 `websocket.ts:3748` 传的是 `data.toString()`，而 `websocket.ts:1393` 是 `new WebSocketServer({ server })` —— 未设 `maxPayload`，ws 默认 100 MiB。单条 100MB 的畸形 JSON 会同步阻塞事件循环完成 parse。`backup_prompt_history.data`（2122）、`record_prompt_history.text`（2135）也都没有长度上限就直接落盘。
修复方向：`new WebSocketServer({ server, maxPayload: ... })`，并在 `parseClientMessage` 开头加 `if (data.length > MAX) return null`。

---

## 顺带发现（不在 parser.ts，但直接对应审查重点 3/4/5）

- **行缓冲无上限**：`codex-process.ts:575` `private stdoutBuffer = ""` + `:3519` `this.stdoutBuffer += chunk`，只在遇到 `\n` 时切走（3521-3524），没有任何长度上限。Codex 进程输出一行超长 JSON（或永不换行）会让该字符串无界增长。建议加 max-line 保护并在超限时丢弃到下一个换行。
- **UTF-8 chunk 边界处理正确**：`codex-transport.ts:80/85/242/243` 用了 `setEncoding("utf8")`，Node 内部走 StringDecoder，多字节不会在 chunk 边界被切断。这一点没问题。
- **delta 切分未破坏 surrogate pair**：`websocket.ts:9834` 的 `splitDeltaText` 用 `for (const char of text)` 按 code point 迭代，emoji/代理对不会被从中间切开；`queueDeltaForClient`（9789-9830）按 client+session 分桶、同类型 delta 直接 `last.text += chunk.text` 追加，`flushSessionDeltaBatches`（9774）在任何非 delta 消息广播前先 flush，保证了 delta 与最终 assistant 消息的顺序。这块实现是对的。

---

## 已检查、确认无问题的点

- `JSON.parse` 异常、`"null"`/`"[1]"`/`'"str"'`/数字等非对象顶层 JSON：全部经 try/catch 或 `!msg.type` 落到 `return null`（实测），不抛出、不中断连接。
- 未知 `type`：`default: return null`（2380），不 throw、不断开、不影响后续消息，graceful degradation 成立（问题只在 [4] 描述的"无法区分 + 无 requestId 关联"）。
- `hunks` 元素校验（2206-2213 / 2222-2229 / 2278-2285）用了 `hunk?.file` 可选链，`null` 元素不会崩。
- `get_history_tool_details`（2705-2726）的边界处理是全文件最严谨的：非空、限长、trim 一致性、`new Set(...).size` 去重全都有。
- `client_capabilities.mobileRuntime`（1189-1240）：白名单 key、长度上下界、`nativeCapabilities` 条数 ≤64、key 正则、value 范围，无漏洞。
- `Number.isInteger` / `Number.isSafeInteger` 用在 `maxTurns`/`beforeSeq`/`sinceSeq`/`expectedGoalOperationSequence` 等处均正确（这些能挡住 `Infinity`）。
- 无 `parseInt`/`Date.parse`/`new Date()` 调用，因此不存在 NaN 时间戳解析问题；文件内也没有 `substring`/`slice` 截断字符串的逻辑，不存在 code-unit 截断乱码。
- 原型污染：`JSON.parse` 的 `__proto__` 是 own data property，`hasOnlyKeys`/`Object.keys` 遍历不受影响。
- git 系列全部走 `execFileSync("git", [...])` 数组参数 + `--` 分隔符，无 shell 注入；`worktreePath` 的 `branch.replace(/\//g,"-")` 也堵住了目录穿越。
