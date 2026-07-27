I'll start by exploring the target files.
Let me read the core files.
Now let me check the tests and integration points.
已完成审查。以下是发现（按严重度排序）。

---

## 审查结论概览

**做得好的部分**（不必修改）：offset 权威完全在服务端（`appendChunk` 开工前校验 `before.size !== entry.offset`，不匹配则 409 并回传真实 offset）；同一 transfer 的 PUT/PATCH/cancel/prepare 全部经 `withTransferLock` 串行化；状态文件是单实例内存 + `mutationQueue` 串行 + tmp+fsync+rename 发布，进程内不存在读-改-写竞态，跨进程有 proper-lockfile 独占（且其 update 定时器已 unref）；断电语义用 `rollbackPending`/`rollbackTruncating` 两阶段日志处理得相当扎实；HTTP 层所有 timer 都 `unref()` + `finally clearTimeout`，fd 全部 `finally close`。Bridge 侧**不存在 progress 事件机制**（进度靠每个 chunk 的 `Upload-Offset` 响应），因此"节流/重复"不适用；`totalBytes` 永远由 prepare 声明或 stat 得出，chunked 无 Content-Length 会 411 拒绝，不存在未知大小路径。

---

### [1] P1 — 过期清理抛错未捕获，一个坏 `.part` 会永久瘫痪整个上传子系统

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-upload-store.ts:351-369`

**触发场景**：任意一个已过期（`retainUntil <= now`）的 pending 条目，其 `.part` 文件 inode 被替换、被改成目录/符号链接，或分片目录发生重绑定导致 `controlledPartialPath` 不匹配。

**证据**：

```ts
await this.withTransferLock(original.transferId, async () => {
  if (entry.status === "committing") {
    try { entry = await this.recoverCommit(entry); } catch { /* partial cleanup below */ }
  }
  if (entry.status !== "complete" && entry.partialPath && entry.partialIdentity) {
    const controlled = await this.controlledPartialPath(entry);   // 可抛 409
    await unlinkIfSameInode(controlled, entry.partialIdentity);   // inode 变化即抛 409
  }
  await this.stateStore.removeUpload(entry.transferId);           // 抛错则永不执行
});
```

只有 `recoverCommit` 被 try/catch 包住，unlink 分支没有。`cleanupExpiredLocked()` 被 `init()`（:181）和**每一次** `prepare()`（:211）无条件 await。由于该条目永远不会被删除、`retainUntil` 永远停在过去，此后每次 `init()`/`prepare()` 都会重跑并重抛 —— 包括与该条目毫无关系的新传输、以及正在进行中传输的续传。重启也无法自愈（`initializeFileTransferRuntime` 会 catch 并把整个文件传输功能关掉）。测试 `file-transfer-upload-store.test.ts:536`（"keeps metadata when expired partial cleanup sees a replacement inode"）恰好断言了新的无关 `prepare` 被拒绝，说明"保留元数据"是有意的，但"永久瘫痪"应该不是。

**建议**：把每个条目的清理包进 try/catch，失败时只记 warn 并 `continue`（保留元数据以便人工审查），不要让单条目污染整个循环；对反复失败的条目加计数/隔离标记，避免每次 prepare 都重试全部。

---

### [2] P1 — 上传元数据 256 条上限 × 7 天保留期：7 天内 256 次上传后所有 prepare 直接失败

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-state-store.ts:445-459`、`:109`
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-upload-store.ts:33`、`:351-358`

**触发场景**：手机在 7 天内向 Bridge 发送第 257 个文件。

**证据**：`DEFAULT_MAX_UPLOADS = 256`，`runtime.ts` 未覆盖该选项。完成的上传写入 `finishCommittedLink`（upload-store.ts:616）时 `retainUntil = now + 7天`；`cleanupExpiredLocked` 只删 `retainUntil <= now` 的条目；`pruneDownloads()`（state-store.ts:592）**只裁剪 downloads，从不裁剪 uploads**。于是：

```ts
this.data.uploads = this.data.uploads.filter((item) => item.transferId !== entry.transferId);
if (this.data.uploads.length >= this.maxUploads) {
  throw new Error("File transfer upload metadata capacity reached");
}
```

第 257 次 `prepare` 抛普通 Error → manager 兜底成 `upload_prepare_failed`（manager.ts:617），手机端只看到"无法准备上传"，且此后一周内每次都失败。同样的写入还发生在 append 的每个 chunk（`upsertUpload`），不过那走 filter 路径不受影响。

**建议**：对 `status === "complete"` 的墓碑用独立且短得多的保留期（例如几小时，只需覆盖"响应丢失后重放"窗口），或在容量触顶时按 `updatedAt` 淘汰最旧的 complete 墓碑（pending 条目仍然 fail-closed）。同时把这个 Error 映射成明确的 `FileTransferError`。

---

### [3] P2 — `pending` 且 `offset === sizeBytes` 是死状态：永远无法再 finalize，传输永久卡死

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-upload-store.ts:288-326`、`:371-402`、`:531-535`

**触发场景**（三条都可达）：
1. 0 字节文件：`prepareNewLocked:271-274` 直接调 `finalize`，若 link/目录校验瞬时失败，条目留在 `pending`、`offset=0=sizeBytes`；
2. 最后一个 chunk 写入并已持久化（`appendChunk:469` 写下 `offset === sizeBytes`）之后、`finalize` 内首个 `upsertUpload(committing)` 之前进程被杀 / 磁盘满 / 目标目录被替换；
3. `finalize` 抛非 EEXIST 错误（如 EXDEV、ENOSPC）。

**证据**：恢复路径没有任何一处会对"pending 且已满 offset"重新触发 finalize：

```ts
// append()
entry = await this.reconcilePendingEntry(entry);
if (uploadOffset !== entry.offset) throw new UploadOffsetConflictError(entry.offset);
if (entry.offset + contentLength > entry.sizeBytes) {
  throw new FileTransferError(413, "upload_exceeds_declared_size", ...);   // offset==size 时恒成立
}
```

`contentLength < 1` 也在 :296 被 413 拒绝，因此**任何 PATCH 都无法推进**；`status()` 只做 reconcile；`resumeLocked` 只在 `status === "complete"` 时返回完成，否则原样返回 `ready`。客户端侧 `apps/mobile/lib/features/file_transfer/file_transfer_service.dart:1956` 的 `while (checkpoint.uploadedBytes < checkpoint.sizeBytes)` 会直接跳过循环，然后在 :2016 等 30 秒 `upload_result`——永远等不到，于是进入"prepare→等待→超时→重试"的无限失败循环，`.part` 文件也要挂到保留期结束。

**建议**：在 `status()`、`append()`（reconcile 之后）与 `resumeLocked()` 中统一加一条：`if (entry.status === "pending" && entry.offset === entry.sizeBytes) return this.finalize(entry)`。

---

### [4] P2 — partial 被截短/替换后，取消也会失败，临时文件与状态双双泄漏

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-upload-store.ts:328-349`、`:635-637`

**触发场景**：`.part` 文件被外部截短（`current.size < entry.offset`）、inode 被换、或所在目录被移动。

**证据**：`cancel` 在删除文件前强制走 reconcile：

```ts
if (entry.partialPath && entry.partialIdentity) {
  entry = await this.reconcilePendingEntry(entry);   // size < offset 时抛 409 upload_partial_changed
  ...
}
await this.stateStore.removeUpload(transferId);      // 抛错则不执行
```

`reconcilePendingEntry:635`：`if (!sameInode(...) || current.size < entry.offset) throw 409`。结果是：该 transfer 既不能续传（append 同样走 reconcile）、又不能取消，状态条目和孤儿 `.part` 一直留到保留期结束，然后还可能撞上发现 [1] 变成永久瘫痪。另外 `committing` 状态若 `recoverCommit` 无法恢复（缺 `finalFilename` 等，:561 原样返回），`cancel` 会因 `reconcilePendingEntry` 的 `status !== "pending"` 抛 `upload_state_invalid`（:626-628），同样无法取消。

**建议**：cancel 是"用户明确放弃"语义，应当尽力而为——reconcile/unlink 失败时降级为 best-effort（记 warn，仍删除状态条目并尝试按 inode 匹配删除文件），只有 `complete` 才拒绝。

---

### [5] P2 — gallery：索引与磁盘必然漂移，且无任何对账/孤儿回收

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/gallery-store.ts:218-235`、`:237-254`、`:464-481`

**触发场景**：断电/进程被杀、磁盘写失败。

**证据**：
- `init()` 只解析 index.json，**不校验 `images/` 下文件是否存在**，也不扫描目录回收未被索引引用的孤儿图片。唯一的剔除逻辑在 `bindProviderSessionIdBySourcePath:400-417`，且只针对 `sourcePath` 命中的行。
- `saveIndex()` 用 `writeFile` + `rename`，**没有 fsync**（对比 state-store.ts:601-639 的 `handle.sync()` + `fsyncDirectory`）：掉电可能得到空/截断的 index.json，`init()` 的 catch 会静默 `this.index = []`，**整个图库索引一次性丢失**（图片文件还在，但全部变成孤儿）。
- `delete()`：先 `unlink` 再 splice 再 `saveIndex`。在 unlink 成功、saveIndex 失败或崩溃时，磁盘索引保留已删除条目 → 重启后条目复活，`serveImage` 返回 404；且 `delete()` 无论 unlink 成功与否都返回 `true`。

**建议**：`saveIndex` 改成 open+write+`sync`+rename+目录 fsync；`init()` 增加一次对账（丢弃文件缺失的行、删除未被引用的 `images/*`）；`delete()` 先落盘索引再删文件（或至少把 unlink 失败反映到返回值）。

---

### [6] P2 — gallery 新增图片时"内存已改、磁盘未改、调用方收到失败"三方不一致

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/gallery-store.ts:291-300`、`:343-351`

**证据**：

```ts
this.index.push(meta);
await this.saveIndex();     // 抛错 →
...
} catch (err) {
  console.warn(`[gallery] Failed to add image: ${detail}`);
  return null;              // 调用方以为失败，但 this.index 里已经有这条了
}
```

`saveIndex` 抛错后 `meta` 仍留在内存索引中：`list()` 会列出它、`serveImage` 会照常提供，而 HTTP 上传接口返回 400 "Failed to add image"；重启后该条目又消失，`images/` 下的文件成为孤儿。

**建议**：先 `saveIndex` 成功再 push（或失败时回滚 splice + 删除已复制的目标文件）。

---

### [7] P3 — 下载状态条目仅靠客户端 ack 清理，失败接收会占位 7 天，撞上 256 上限后 offerFile 报 500

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-manager.ts:426-447`

**证据**：`handleReceiveResult` 要求 `message.success && message.receivedBytes === binding.sizeBytes` 才 `remove`。手机端失败路径发送 `receivedBytes: 0`（`file_transfer_service.dart:775`），因此失败的下载条目一直留到 `retainUntil`（7 天）。`DEFAULT_MAX_DOWNLOADS = 256` 且 `upsertDownload`（state-store.ts:398）在触顶时抛普通 Error → `offerFile` 变成 500。与发现 [2] 同源。

**建议**：为失败/取消的接收结果也做一次带鉴权的清理，或给下载条目更短的保留期。

---

### [8] P3 — 每个分片触发 2~3 次全量状态文件重写 + 双重 fsync

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-upload-store.ts:441`、`:469`（+ 回滚路径 :483/:503/:507）与 `file-transfer-state-store.ts:601-639`

每个 PATCH 至少写两次 journal/offset，每次都是把最多 8 MiB 的整份 JSON 序列化 → 临时文件 → `handle.sync()` → rename → `chmod` → 目录 fsync。客户端使用自适应小分片上传 15 GiB 文件时会产生上万次全量重写（写放大 + 明显延迟）。语义上是正确的（崩溃安全），但值得关注吞吐。

**建议**：把 journal 标记与 offset 合并成一次写；或对同一 transfer 的高频 offset 更新采用增量/单条目日志。

---

### [9] P3 — 并发上限检查位于 transfer 锁内，无法限制排队请求数；HTTP 层无上传并发闸门

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-upload-store.ts:311-314`、`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-http.ts:261-335`

`this.activeUploads >= this.maxActiveUploads`（默认 2）的检查发生在拿到 transfer 锁、完成鉴权与 reconcile 之后，因此只能限制"正在写盘"的数量，不能限制排队等待的请求数。下载侧有 `activeDownloads` + `activeDownloadIds` 在 HTTP 层同步预留（http.ts:189-195），上传侧没有对应闸门。同一 transferId 的多个 PATCH 会在锁队列上无界堆积。

**建议**：在 `handleUpload` 入口同步预留一个上传槽位（对齐下载侧写法），并对同一 transferId 的并发 PATCH 直接 409/429 快速失败。

---

### [10] P3 — 上传只监听已废弃的 `req 'aborted'`，未监听 `res 'close'`

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-http.ts:303-305`

```ts
const controller = new AbortController();
const abort = (): void => controller.abort();
req.once("aborted", abort);     // 对比 handleSendControl:131-133 还注册了 res.once("close", abort)
```

响应侧 socket 被关闭而请求未触发 `aborted` 时，只能靠 60 秒 idle timer 兜底；在这段时间内 transfer 锁被占用，客户端立刻发起的续传 PATCH 会被阻塞最长 60 秒。

**建议**：与 `handleSendControl` 一致，补上 `res.once("close", abort)`，并考虑改用 `res.on("close")`/`req.destroyed` 代替已废弃的 `aborted`。

---

### [11] P3 — 完成事件依赖活跃 WS 绑定，断线即丢失

`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/file-transfer-manager.ts:568-603`、`:107-123`

`sendCompletedUpload` 从 `uploadClients` 取绑定，而 `disconnect()` 会清空该 transfer 的绑定。若最后一个 chunk 完成时 WS 恰好断开，`upload_result` 直接丢弃（`if (!owner) return`），只能靠手机重新 `prepare` 命中完成墓碑来补发（manager.ts:397-400）——而墓碑的存活又受发现 [2] 的容量/保留期约束。重复方向是安全的（重复 PATCH 会被 `upload_already_complete` 拦下），只有"丢失"这一侧存在。

**建议**：在完成时把结果暂存到一个短期待投递队列，客户端重连（或下一次任意 WS 消息）时补投，而不是完全依赖客户端主动重新 prepare。

---

### 补充：状态机可回退性

`upsertUpload` 本身不做状态迁移校验，`recoverCommit` 会主动把 `committing` 写回 `pending`（upload-store.ts:574、:582）以重试文件名冲突——这是有意设计且安全（`complete` 在 `finalize:533`、`cancel:336`、`resumeLocked:388` 三处都优先短路，不会被回退）。所有写路径都在同一个 `withTransferLock` 下，因此不存在陈旧快照覆盖终态的窗口。这一点没有问题，仅提示：由于校验只在 `isUpload()` 的形状层面（state-store.ts:887-929），未来若新增绕过 transfer 锁的写入方，终态可被覆盖的风险会立刻出现，建议在 `upsertUpload` 里加一条 "complete 不可被降级" 的断言作为纵深防御。
