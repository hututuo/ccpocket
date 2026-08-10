# CC Pocket Desktop 实时消息停更恢复 v01

状态：根因确认、源码修复、本地验证与独立复审完成，等待发布门禁

基线：`27db7201b341d5a30843c30f0d87e63f80a4aaa5`

## 现场证据

- 生产 Bridge `compat.31-27db7201` 的 `/health` 与 `/readyz` 正常，手机仍有一个
  WebSocket client，证明本次不是整体断线或 Bridge readiness 失败。
- Mobile 的 `conversation_sync_v2` subscription 能完成 priority/bootstrap，并持续产生
  更高 sequence；但 Desktop 已新增消息时，手机仍停留在旧 snapshot。
- 同期 Bridge stderr 明确出现 `Codex daemon version check ... ETIMEDOUT`，随后连续记录
  `Canonical timeline temporarily unavailable (CodexRpcError)`。历史读取失败时，v2 按
  既有 fail-soft 逻辑保留 previous snapshot，因此形成“状态变化但正文不变”。
- 源码审计确认：observer 排除条件用两个负向比较判断 `controlState`；因此没有 process/
  controlState 的 detached Codex session 也会因为 `undefined !== unavailable/reconciling` 被
  误判为已有直接消息流。真正的 formal adoption（无论 turn 由 Bridge 还是 Desktop 发起）
  会经 SessionManager 转发 app-server notification，并继续与 observer 互斥。
- 每个 Codex attachment 都调用 daemon exact verification；旧缓存仅 2 秒，并通过同步
  `spawnSync` 执行版本命令。在会话目录、历史、设置、额度和 observer 并发建立连接时，
  这个热路径会重复创建子进程，超时后同时打断 catalog 与 timeline 读取。

## 修复

1. 只有明确存在 usable `controlState` 的 formal runtime attachment 才跳过 shared content
   observer；仅有 detached SessionInfo、没有 controlState 的线程继续使用最多 32 个、有
   并发上限的只读观察器。Desktop-hosted formal adoption 仍走既有 session stream，避免双流。
2. daemon 首次 exact verification 完整保留。之后每次 attachment 仍检查安全目录、所有权、
   权限、CLI file identity 与 socket identity；identity 未变时直接复用已验证版本结果，
   不再按时间重复同步 spawn。CLI 原地变化或 socket 被替换会立即重新核验。
3. 不改变 `conversation_sync_v2` wire、Mobile SQLite schema、authority generation、writer
   lease、旧 Mobile/Bridge 协商或 provider 历史权威性。

## 验证结果

- 定向 Vitest：daemon supervisor 与 conversation sync 共 `154/154` 通过，覆盖 detached
  observer、Bridge-owned/Desktop-hosted formal stream 去重、CLI 原地变化和 socket 替换失效。
- TypeScript `tsc --noEmit` 与 `git diff --check` 通过。
- Bridge 单 worker 全量：`118` files、`2415/2415` tests 通过。并行全量仅有既有
  `session-catalog-monitor` 固定 5 秒超时；该文件隔离复跑 `9/9` 通过，判定为并行资源竞争。
- `npm run test:bridge` 的 pretest 已完成 TypeScript 与 native file-browser helper build。
- 隔离候选连接真实 shared daemon 后，对当前 Desktop 托管线程保持同一 v2 subscription；
  初始 revision `259c3757ff9a1647`，Desktop 新增内容后无需重连即收到 patch，revision 变为
  `f43566dd194f6a45`。候选已停止，生产未切换。
- 另以 `sharedRuntimeAttach=adoption` 只读附着当前 Desktop 线程，不重连、不由探针发送
  input；Desktop 产生新内容后，该 formal attachment 实时收到连续 `stream_delta` 与稳定
  assistant item `msg_07d067f29e687b3c016a796236400c819190dd6634c3365f0b`，随后正常
  stop。该证据确认 Desktop-hosted formal attachment 的 session stream 完整存在，observer
  与 adoption 继续互斥是正确行为。
- Luna Max 独立只读复审结论 `LGTM / NO BLOCKER`。保留一个非阻断 P2：当前 daemon exact
  identity 没有 PID/boot token；若未来支持继承同一 socket FD/inode 的进程热替换，应把该
  token 加入 cache identity。当前受审生命周期会在重启时替换 socket，故维持既定安全边界。
- 生产切换与 Mobile/真机验收是独立门禁；未经新的发布授权不替换当前 runtime。
