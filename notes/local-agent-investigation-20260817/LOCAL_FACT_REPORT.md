# CC Pocket v3 本地事实调查报告

调查日期：2026-08-17  
调查基线：`main @ 7db4efe5e857c24752825a2a2f2fbba3eda32c1d`  
调查结论：当前源码和测试能证明若干传输/缓存不变量，但不能证明“真实 Desktop + 真实 Bridge + 真实 WSS + Dart SQLite + Cubit + 渲染”整链路已经闭环。最关键的运行时风险是 Desktop bundle `0.148.0-alpha.9` 与 daemon `0.146.0` 不同版本；最关键的 app-server 事实是 `thread/items/list` 在 0.146.0 实际不支持、首条用户消息前 `thread/turns/list` 不可用、重复 `clientUserMessageId` 不会由 app-server 去重。

## 0. 调查边界、状态含义和隔离

本轮只使用了：

- 只读查看当前 Desktop 进程、版本、环境和 UDS 文件描述符；
- 独立 `CODEX_HOME`、独立 standalone package symlink、独立 app-server daemon、独立 throwaway project；
- raw WebSocket JSON-RPC 客户端 A/B；
- Bridge 的源代码、已有测试和隔离 synthetic benchmark；
- Mobile 的源码、sqflite_ffi 测试代码和现有 fixture 的静态审阅。

没有做：生产 Bridge 重启/替换、launchctl 写入、Desktop 退出/重启、真实会话写入、真实凭据读取、IPA/OTA/Cloud 发布、物理 iPhone 操作。

状态定义：

- `PASS`：本轮有直接、可复现的证据支持该命题；
- `FAIL`：直接证据与该命题相反；
- `UNSUPPORTED`：目标能力在当前版本/环境没有可用接口，或安全边界禁止实测；
- `UNKNOWN`：证据不足，不能用推断代替实测。

原始输出均在 [`raw/`](raw/)；所有路径、PID、socket 地址、线程 ID、消息正文和敏感标识已脱敏。

## 1. 逐项调查台账

### D-01 Desktop 是否遵守 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`

**Result: PASS（当前运行实例）；精确版本门禁另见 D-02。**

- **Environment:** Desktop build `26.810.52044 / 6662`；当前 GUI 进程；只读。
- **Exact commands/actions:**
  `ps eww -p <DESKTOP_PID> -o command= | tr ' ' '\n' | rg 'CODEX_APP_SERVER_USE_LOCAL_DAEMON|CODEX_HOME'`；`/Applications/ChatGPT.app/Contents/Resources/codex --version`；`codex app-server daemon version`。
- **Raw evidence files:** [`raw/01-live-desktop-daemon.txt`](raw/01-live-desktop-daemon.txt)。
- **Source file and lines:** Desktop bundle 没有可读源码；项目事务/门禁的实现和测试在 [`packages/bridge/src/codex-desktop-shared-runtime.test.ts:93-148`](<REPO>/packages/bridge/src/codex-desktop-shared-runtime.test.ts:93) 与 [`decisions.md:1748-1751`](<REPO>/decisions.md:1748)。
- **Observed behavior:** GUI 环境包含 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`；Desktop 的 socket FD 与 daemon FD 指向同一 kernel endpoint。
- **Interpretation:** 当前 build 的确走了 local-daemon gate；这不是“只在配置文件里写了变量”的推断。
- **Risk:** 该证据只覆盖当前运行实例，不证明用户下一次切换或新安装后的行为。
- **Recommended v3 decision:** 把进程环境和 UDS endpoint 作为启动后的硬验收；不要用静态 bundle 搜索替代运行证据。

### D-02 Desktop shared 后是否连接目标 UDS 的精确 inode、且版本是否相符

**Result: PASS（endpoint）；FAIL（exact-version pilot gate）。**

- **Environment:** 当前 `~/.codex/app-server-control/app-server-control.sock`；只读 `stat`/`lsof`。
- **Exact commands/actions:**
  `stat -f 'mode=%Sp inode=%i dev=%d type=%HT' <SOCK>`；`lsof -nP -a -p <DESKTOP_PID> -U`；`lsof -nP -a -p <DAEMON_PID> -U`；`codex app-server daemon version`。
- **Raw evidence files:** [`raw/01-live-desktop-daemon.txt`](raw/01-live-desktop-daemon.txt)。
- **Source file and lines:** UDS transport验收测试见 [`packages/bridge/src/codex-transport.test.ts:171-301`](<REPO>/packages/bridge/src/codex-transport.test.ts:171)；精确版本要求见 [`decisions.md:1736-1738`](<REPO>/decisions.md:1736)。
- **Observed behavior:** Desktop 和 daemon 的 `lsof` endpoint 相同；daemon `managedCodexVersion/cliVersion/appServerVersion=0.146.0`，但 Desktop bundled Codex 是 `0.148.0-alpha.9`。
- **Interpretation:** 连接的是目标 socket，但不是项目要求的“Desktop bundled Codex 与 daemon exact version”。
- **Risk:** 协议字段、通知和 cursor 语义可能在 alpha 版本间变化；当前 shared pilot 不应把它标为通过。
- **Recommended v3 decision:** 先锁定 Desktop 实际 bundled version，再用同一版本建立 daemon；版本不一致时状态为 blocked，而不是仅凭 socket 相同继续运行。

### D-03 shared 后 Desktop 是否仍启动 private stdio app-server

**Result: PASS（当前采样）。**

- **Environment:** 当前 Desktop 进程树；只读。
- **Exact commands/actions:**
  `ps -axo pid=,ppid=,command= | rg 'codex app-server.*stdio|codex app-server --listen stdio'`；同时检查 Desktop 子进程树。
- **Raw evidence files:** [`raw/01-live-desktop-daemon.txt`](raw/01-live-desktop-daemon.txt)。
- **Source file and lines:** 共享事务的无 private stdio 断言见 [`packages/bridge/src/codex-desktop-shared-runtime.test.ts:283-312`](<REPO>/packages/bridge/src/codex-desktop-shared-runtime.test.ts:283)。
- **Observed behavior:** 当前采样没有 `codex app-server --listen stdio` 子进程；只有 daemon 的 remote-control UDS 进程。
- **Interpretation:** 当前 GUI 没有同时持有一棵可见的 private stdio app-server。
- **Risk:** 一次进程树采样不能覆盖 Desktop 后续重连/升级后的瞬间状态。
- **Recommended v3 decision:** 发布/切换后再次做进程树 + UDS FD 双证据，不能只看环境变量。

### D-04 首次切换是否必须完整退出并重启 Desktop

**Result: UNKNOWN。**

- **Environment:** 未对生产 Desktop 做切换或重启，避免改变用户 GUI 环境。
- **Exact commands/actions:** 没有执行 `enable-shared`、`restore-private`、`kill` 或 `open -a ChatGPT`；只审阅已有事务测试。
- **Raw evidence files:** [`raw/01-live-desktop-daemon.txt`](raw/01-live-desktop-daemon.txt)；事务测试见 [`packages/bridge/src/codex-desktop-shared-runtime.test.ts:93-188`](<REPO>/packages/bridge/src/codex-desktop-shared-runtime.test.ts:93)。
- **Source file and lines:** 项目只规定使用既有环境 gate，见 [`decisions.md:1748-1751`](<REPO>/decisions.md:1748)；没有当前 Desktop GUI 的 restart contract 源码。
- **Observed behavior:** 当前实例已经处于 shared gate，但没有 A/B 切换时序数据。
- **Interpretation:** 不能把“现在已经连接”推导成“首次切换无需完全退出”。
- **Risk:** 如果环境只在 GUI 启动时读取，热切换会产生旧连接残留；如果能热读，盲目重启又会打断会话。
- **Recommended v3 decision:** 在隔离的 Desktop harness 或用户明确授权的测试窗口中做一次 `captured → enabling → shared` 时序实验；在此之前产品门禁保持 UNKNOWN/不自动切换。

### D-05 切换失败、中途 kill 后能否精确恢复原 GUI 环境

**Result: PASS（事务实现/隔离单测）；UNKNOWN（真实 Desktop kill）。**

- **Environment:** 隔离 fake GUI environment map + 临时事务目录；没有 launchctl 写入。
- **Exact commands/actions:** 运行 `packages/bridge/src/codex-desktop-shared-runtime.test.ts` 的事务测试，包括 enable 失败、`enabling`/`restoring` interrupted recovery。
- **Raw evidence files:** [`raw/05-source-and-protocol-index.txt`](raw/05-source-and-protocol-index.txt)；测试源码 [`packages/bridge/src/codex-desktop-shared-runtime.test.ts:218-280`](<REPO>/packages/bridge/src/codex-desktop-shared-runtime.test.ts:218)。
- **Source file and lines:** 同上；测试覆盖捕获原值、失败回滚、恢复 interrupted transaction。
- **Observed behavior:** 测试断言失败后 `CODEX_HOME` 原值和 gate 恢复，事务状态为 `restored`。
- **Interpretation:** 软件事务层有可验证回滚，但这不是对真实 GUI/launchd kill 的证明。
- **Risk:** GUI 进程可能在环境恢复前退出或产生新子进程，真实 kill 时序尚未测。
- **Recommended v3 decision:** 继续使用事务文件 + 原值校验；把真实 kill/重启恢复列为独立人工验收，不把单测标成设备通过。

### D-06 普通交互式 Codex CLI 加入同一 daemon 的正式方式

**Result: PASS（命令接口存在）；实际 TUI attach smoke 为 UNKNOWN。**

- **Environment:** standalone CLI `0.146.0`；只读取 help，没有启动 TUI。
- **Exact commands/actions:** `codex resume --help`；`codex app-server proxy --help`；`codex remote-control --help`。
- **Raw evidence files:** [`raw/02-isolated-daemon-and-proxy.txt`](raw/02-isolated-daemon-and-proxy.txt)；命令原始 help 见调查运行记录。
- **Source file and lines:** 当前可审计“接口源”是已安装 CLI 的 help/schema；项目 transport 封装见 [`packages/bridge/src/codex-transport.test.ts:278-301`](<REPO>/packages/bridge/src/codex-transport.test.ts:278)。
- **Observed behavior:** `codex resume` 明确提供 `--remote <ADDR>`，接受 `unix://`/`unix://PATH`/`ws://`/`wss://`；没有单独的 `--daemon` TUI 参数。
- **Interpretation:** 普通交互式 CLI 的正式 attach 入口是 `codex resume --remote unix://<SOCK> [THREAD_ID]`，而不是把 daemon 当作 stdio。
- **Risk:** 本轮未在隔离 daemon 上启动完整 TUI，因此不能证明首屏、输入和退出行为。
- **Recommended v3 decision:** v3 用 `--remote unix://PATH` 做 CLI attach smoke；Bridge 不伪造 TUI 协议，也不把 `proxy` 当成 TUI。

### D-07 `codex app-server proxy` 是什么

**Result: PASS：raw WebSocket byte proxy；FAIL：不能把它当普通交互式 CLI。**

- **Environment:** 隔离 daemon/UDS；子进程 `codex app-server proxy --sock <SOCK>`。
- **Exact commands/actions:** 启动 proxy；通过 stdin 写 WebSocket HTTP Upgrade、masked text frame 和 `initialize` JSON-RPC；读取 stdout。
- **Raw evidence files:** [`raw/02-isolated-daemon-and-proxy.txt`](raw/02-isolated-daemon-and-proxy.txt)。
- **Source file and lines:** `codex app-server proxy --help` 文案是 “Proxy stdio bytes to the running app-server control socket”；Bridge UDS transport framing 见 [`packages/bridge/src/codex-transport.test.ts:171-225`](<REPO>/packages/bridge/src/codex-transport.test.ts:171)。
- **Observed behavior:** proxy 返回 HTTP 101，并转发 initialize response；直接向 UDS/ proxy 写裸换行 JSON 会触发 WebSocket protocol/httparse invalid token。
- **Interpretation:** proxy 是字节级 stdio↔WebSocket 代理；上层必须自己实现 WebSocket framing + JSON-RPC。它不是交互式 TUI client。
- **Risk:** 调用方若把裸 JSON 当 stdio app-server 协议，会得到“没有响应/invalid token”，这正是容易造成 Bridge 卡住的兼容误判。
- **Recommended v3 decision:** Bridge 只使用已验证的 WebSocket transport；交互式 CLI 使用 D-06 的 `resume --remote`。

### R-01 两个 raw JSON-RPC client 同时连接的通知范围

**Result: PASS（当前可观察的 global/thread 状态通知）。**

- **Environment:** 隔离 daemon UDS；raw clients A/B 均 `experimentalApi=true`。
- **Exact commands/actions:** A/B `initialize`；A `thread/start`；A `turn/start`；两端收集通知。
- **Raw evidence files:** [`raw/03-two-client-rpc-and-methods.txt`](raw/03-two-client-rpc-and-methods.txt)。
- **Source file and lines:** shared runtime 设计明确“server request 可送达多个订阅者”见 [`decisions.md:1743-1747`](<REPO>/decisions.md:1743)；Bridge shared control request 只在内存观察见 [`packages/bridge/src/codex-shared-runtime-control.test.ts:169-243`](<REPO>/packages/bridge/src/codex-shared-runtime-control.test.ts:169)。
- **Observed behavior:** A/B 都收到 `thread/started` 和 `thread/status/changed`；事件计数各为 1。
- **Interpretation:** 这些通知不是“只发给发起 turn 的连接”；Bridge 不能按单 socket 私有事件假设设计。
- **Risk:** server request/approval 的响应仍是 first response wins，不能因为两端都收到通知就允许两端都答复。
- **Recommended v3 decision:** 通知广播按 thread/source/generation 过滤；控制请求必须绑定 connection generation、threadId、turnId 和 writer authority。

### R-02 `thread/unsubscribe` 是否抑制所有后续 thread/turn 通知

**Result: UNKNOWN。**

- **Environment:** 隔离 daemon；A 执行 `thread/unsubscribe` 后启动无认证 provider turn。
- **Exact commands/actions:** A `thread/unsubscribe(threadId)`；A `turn/start`；A/B 等待 1.8 秒，比较 thread-scoped event。
- **Raw evidence files:** [`raw/03-two-client-rpc-and-methods.txt`](raw/03-two-client-rpc-and-methods.txt)。
- **Source file and lines:** schema 的 `ThreadUnsubscribeParams` 仅要求 `threadId`；Bridge v2 自己的 unsubscribe 是另一层协议，见 [`packages/bridge/src/local-features/slots/conversation-sync-v2-protocol.ts:82-87`](<REPO>/packages/bridge/src/local-features/slots/conversation-sync-v2-protocol.ts:82)。
- **Observed behavior:** unsubscribe response 是 `unsubscribed`；由于 provider 未认证，实验只观测到 thread/status 级事件，没有稳定的 `turn/started`/delta/completed 样本。
- **Interpretation:** 不能从这次无 provider 事件的窗口推导完整 suppression 语义。
- **Risk:** Bridge 若把 unsubscribe 当成“停止所有全局通知”，可能漏掉 status/approval；若完全不抑制，又会产生旧订阅泄漏。
- **Recommended v3 decision:** 加入隔离 fake provider 的通知矩阵：unsubscribe 前后分别验证 thread/status/turn/server-request 四类事件；未完成前保持 UNKNOWN。

### R-03 冷 thread 的通知、首次 materialization 和列表发现

**Result: FAIL（立即列表可见性）；PASS（有 thread/started 通知）；UNKNOWN（Desktop sidebar）。**

- **Environment:** 隔离 daemon，throwaway thread，无生产 GUI。
- **Exact commands/actions:** A `thread/start` 后 350 ms 内 B `thread/list(useStateDbOnly=true, sortKey=recency_at)`；随后首个 turn；重启后再次 list。
- **Raw evidence files:** [`raw/03-two-client-rpc-and-methods.txt`](raw/03-two-client-rpc-and-methods.txt)、[`raw/04-cursor-restart.txt`](raw/04-cursor-restart.txt)。
- **Source file and lines:** 项目决策已警告 `thread/started` 不是可写/可 resume 证明，见 [`decisions.md:1739-1742`](<REPO>/decisions.md:1739)。Bridge cold pass 当前是长周期 catalog/status reconcile，见 [`packages/bridge/src/local-features/conversation-sync-v2.ts:6254-6299`](<REPO>/packages/bridge/src/local-features/conversation-sync-v2.ts:6254)。
- **Observed behavior:** fresh state 中 `thread/started` 已广播，但首个 `thread/list` 返回 0；turn 持久化/daemon restart 后才出现在 list。Desktop sidebar 未做真实 GUI 操作。
- **Interpretation:** “收到 started 就立即把冷 thread 当完整目录项”是错误的；通知和 state DB materialization 有时间差。
- **Risk:** 手机首页/Bridge registry 可能短暂缺少新 thread，或把未物化 thread 当成可写目标。
- **Recommended v3 decision:** 将 `started`, `materialized`, `resumable`, `sidebar-visible` 分成四个状态；目录以 state DB/rollout materialization 为准，started 只做候选提示。

### R-04 itemId/turnId 稳定性

**Result: UNKNOWN（完整生命周期）；PASS（已持久化样本的稳定复读）。**

- **Environment:** 隔离 daemon；无认证 provider，只有 app-server persistence 边界可测。
- **Exact commands/actions:** `turn/start`；`thread/turns/list`；daemon restart；用同一 thread 重新 list/resume。
- **Raw evidence files:** [`raw/04-cursor-restart.txt`](raw/04-cursor-restart.txt)。
- **Source file and lines:** Bridge canonical normalization 保留 provider turn/item ID，见 [`packages/bridge/src/local-features/conversation-mirror.ts:231-281`](<REPO>/packages/bridge/src/local-features/conversation-mirror.ts:231)；Mobile projection 只以 stable alias/id 去重，见 [`apps/mobile/lib/features/chat_session/state/detached_timeline_projection.dart:32-128`](<REPO>/apps/mobile/lib/features/chat_session/state/detached_timeline_projection.dart:32)。
- **Observed behavior:** persisted page 在 daemon restart 后可复读；但没有 authenticated started/delta/completed/history 全链样本。
- **Interpretation:** 不能声称所有事件阶段的 ID 都已实测稳定；源码策略是保留 provider ID，缺失时才使用 digest/turn-scoped fallback。
- **Risk:** fallback identity 一旦跨 turn 或跨 source 复用，会造成手机重复/串轮。
- **Recommended v3 decision:** provider itemId/turnId 必须是 canonical；fallback 只能带 source+turn scope，并在诊断中明确 `identityConfidence=unknown`。

### R-05 重复 `clientUserMessageId` 的 app-server 行为

**Result: FAIL（app-server 自身不去重）。**

- **Environment:** 隔离 daemon；同一 thread；两个相同 `clientUserMessageId` 的 `turn/start`。
- **Exact commands/actions:** 连续两次发送 `turn/start(... clientUserMessageId=<same>)`，比较响应 turn ID。
- **Raw evidence files:** [`raw/03-two-client-rpc-and-methods.txt`](raw/03-two-client-rpc-and-methods.txt)。
- **Source file and lines:** app-server schema 的 `TurnStartParams` 有 `clientUserMessageId` 字段（生成 schema `<EXP_SCHEMA>/schema/codex_app_server_protocol.v2.schemas.json`）；Bridge ledger 入口见 [`packages/bridge/src/session.ts:2591-2626`](<REPO>/packages/bridge/src/session.ts:2591) 和 [`packages/bridge/src/session.ts:3328-3397`](<REPO>/packages/bridge/src/session.ts:3328)。
- **Observed behavior:** 两次 response 都成功，返回不同 turn ID，`equal=false`。
- **Interpretation:** `clientUserMessageId` 不是 app-server 的全局幂等键；它只能被 Bridge input-delivery ledger 用来防重。
- **Risk:** Mobile 重连后盲目再次 `turn/start` 会真实创建第二轮，正好对应旧消息误发/一条变三条的根因类型。
- **Recommended v3 decision:** Bridge admission/ledger 是唯一重试权威；移动端只能重发同 ID 到 Bridge，不可直接向 app-server 重放。

### R-06 `thread/turns/list` cursor 在追加、restart、compact 下的行为

**Result: PASS（persisted cursor across restart）；FAIL（turn/start 后立即可见性）；UNSUPPORTED（compact 本轮）。**

- **Environment:** 隔离 daemon；throwaway thread。
- **Exact commands/actions:** 首次 `thread/turns/list` 保存 cursor；daemon restart 后复用；再 `turn/start` 后立即请求第一历史页；未执行 provider-auth compact。
- **Raw evidence files:** [`raw/04-cursor-restart.txt`](raw/04-cursor-restart.txt)。
- **Source file and lines:** Bridge adapter 检查重复 cursor、反向页和分页边界，见 [`packages/bridge/src/local-features/codex-bounded-history.ts:164-207`](<REPO>/packages/bridge/src/local-features/codex-bounded-history.ts:164) 与 [`:301-320`](<REPO>/packages/bridge/src/local-features/codex-bounded-history.ts:301)。
- **Observed behavior:** 已持久化 page/cursor 在 daemon restart 后同样返回；新 turn `inProgress` 的即时 response 不会让 history page 立即出现新内容。
- **Interpretation:** turn acknowledgement 与 durable history commit 是两个时点；cursor 读取不能被“turn/start 成功”触发的 UI 乐观替换抢先覆盖。
- **Risk:** 手机会跳回旧缓存或把 runtime overlay 当 canonical，造成消息消失、重复和顺序错乱。
- **Recommended v3 decision:** 只有 history commit/revision 前移后更新 canonical；active turn 用独立 overlay，compact 需再做真实 provider fixture。

### R-07 `thread/items/list` 在当前 0.146.0 是否可用

**Result: FAIL（实际 runtime 返回 unsupported）。**

- **Environment:** standalone 0.146.0 isolated daemon；schema 与 runtime 同时检查。
- **Exact commands/actions:** 生成 `--experimental` schema；raw client 调 `thread/items/list`。
- **Raw evidence files:** [`raw/03-two-client-rpc-and-methods.txt`](raw/03-two-client-rpc-and-methods.txt)、[`raw/05-source-and-protocol-index.txt`](raw/05-source-and-protocol-index.txt)。
- **Source file and lines:** Bridge adapter明确将 `-32601`/unsupported 归为 fallback，见 [`packages/bridge/src/local-features/codex-bounded-history.ts:376-398`](<REPO>/packages/bridge/src/local-features/codex-bounded-history.ts:376)；Mirror reader先 items、再 turns，见 [`packages/bridge/src/local-features/conversation-mirror.ts:151-175`](<REPO>/packages/bridge/src/local-features/conversation-mirror.ts:151)。
- **Observed behavior:** runtime error `code=-32601, thread/items/list is not supported yet`，尽管生成 schema 中有该方法。
- **Interpretation:** schema 能力声明不是 runtime capability proof；当前必须以 turns fallback/Bridge probe 为准。
- **Risk:** Mobile/Bridge 若只相信 schema，会在会话打开时卡在“加载/重试”。
- **Recommended v3 decision:** 连接后做一次 method capability probe；把 unsupported 作为明确 turns fallback，不重复发送同一个必失败 RPC。

### R-08 100 turns/10k/50k items 的性能

**Result: PASS（当前 synthetic/adapter 目标）；UNKNOWN（真实 provider/network/UI）。**

- **Environment:** isolated `CODEX_HOME` synthetic benchmark；纯本地 normalizer；fake page adapter；Bridge tests。
- **Exact commands/actions:** 见 [`raw/06-performance-and-tests.txt`](raw/06-performance-and-tests.txt) 中列出的三个 Node benchmark 和 Vitest 命令。
- **Raw evidence files:** [`raw/06-performance-and-tests.txt`](raw/06-performance-and-tests.txt)。
- **Source file and lines:** Bridge synthetic benchmark [`packages/bridge/scripts/benchmark-conversation-sync-v2.mjs:1-240`](<REPO>/packages/bridge/scripts/benchmark-conversation-sync-v2.mjs:1)；normalizer [`packages/bridge/src/local-features/conversation-mirror.ts:217-317`](<REPO>/packages/bridge/src/local-features/conversation-mirror.ts:217)；reader [`packages/bridge/src/local-features/codex-bounded-history.ts:164-207`](<REPO>/packages/bridge/src/local-features/codex-bounded-history.ts:164)。
- **Observed behavior:** isolated catalog=1500 complete p95≈50.55 ms；catalog=10000 complete p95≈97.00 ms；normalizer 10k≈58.24 ms、50k≈214.62 ms；fake adapter 10k≈2.97 ms、50k≈15.80 ms；max synthetic frame 57,603 bytes。
- **Interpretation:** 当前算法/帧预算在本地 synthetic 数据上有界；这不是真实 app-server 读盘、网络、SQLite commit 或 Widget mount 的 p95。
- **Risk:** provider rollout parse、WSS backpressure、Dart JSON decode/SQLite transaction 和 UI layout 仍可能成为实际热点。
- **Recommended v3 decision:** 保留 synthetic benchmark，并新增真实 Bridge WSS + Dart headless sink 的同样计时；不要用 synthetic p95 宣称手机体验达标。

### R-09 冷会话状态与运行中会话的监控机制

**Result: UNKNOWN（daemon/shared cold detection）；FAIL（旧 private monitor 不能当 shared daemon 的同一事实源）。**

- **Environment:** 源码审计；没有对真实 session 进行扫描或写入。
- **Exact commands/actions:** `rg`/`nl` 检查 daemonMode、external monitor、cold timer、rollout monitor；没有生产轮询。
- **Raw evidence files:** [`raw/05-source-and-protocol-index.txt`](raw/05-source-and-protocol-index.txt)。
- **Source file and lines:** `ConversationSyncV2FeatureHandler` 在 daemonMode 下设置 `legacyCodexMonitoringEnabled = !daemonMode`，见 [`conversation-sync-v2.ts:770-787`](<REPO>/packages/bridge/src/local-features/conversation-sync-v2.ts:770)；cold reconcile 默认 10 分钟，见 [`:115-118`](<REPO>/packages/bridge/src/local-features/conversation-sync-v2.ts:115) 和 [`:6254-6299`](<REPO>/packages/bridge/src/local-features/conversation-sync-v2.ts:6254)；private rollout monitor 的 fs.watch/active 750 ms/idle 10 s 在 [`slots/codex-desktop-continuity.ts:1260-1361`](<REPO>/packages/bridge/src/local-features/slots/codex-desktop-continuity.ts:1260)。
- **Observed behavior:** shared daemon 路径依赖 shared control/observer；private rollout tail monitor 在 daemonMode 关闭。冷对账是长周期 catalog/status repair，不是每个 thread 高频读正文。
- **Interpretation:** 不能把 private rollout monitor 的实时性直接推导给 shared daemon；shared cold thread 的“立即发现”必须依靠 app-server notification + state DB/rollout marker fallback 的组合。
- **Risk:** Desktop-owned thread 在 Bridge 没有订阅/observer interest 时可能只在冷对账后出现；这正是手机看到旧缓存的候选原因。
- **Recommended v3 decision:** 建立冷 thread discovery contract：notification candidate → state DB materialization → bounded latest-turn hydration；每层记录 receipt 和缺口，不把 tail scan 当 canonical。

### R-10 多 client approval 请求与 resolved 路由

**Result: UNSUPPORTED（本轮没有 authenticated provider approval）；PASS（Bridge 自己的 exact-generation 安全边界）；FAIL/禁止（独立 Desktop-owned approval 由 Bridge 跨连接代答）。**

- **Environment:** 只使用隔离 control 单测和源码；没有向真实 provider 发命令。
- **Exact commands/actions:** 运行/审阅 `codex-shared-runtime-control.test.ts` server request 测试；未触发生产 approval。
- **Raw evidence files:** [`raw/05-source-and-protocol-index.txt`](raw/05-source-and-protocol-index.txt)；单测源码 [`packages/bridge/src/codex-shared-runtime-control.test.ts:169-243`](<REPO>/packages/bridge/src/codex-shared-runtime-control.test.ts:169)。
- **Source file and lines:** 该测试证明请求只在内存观察、generation 不相符时拒答；产品决策明确 Bridge 不能回答独立 Desktop app-server 的 approval，见 [`decisions.md:1043-1048`](<REPO>/decisions.md:1043)。
- **Observed behavior:** 同一 control connection 的 approval 可在 exact generation 回答；旧 generation 返回 false。真实双 client approval 的 first-response-wins 未在 provider 上实测。
- **Interpretation:** “手机退出后 Bridge 自动批准”只适用于 Bridge 自己拥有的 live authority，不适用于独立 Desktop-owned request。
- **Risk:** 若 Bridge 把广播通知误当写权，会出现双答复、错误 thread 或越权批准。
- **Recommended v3 decision:** approval 台账绑定 source/thread/turn/request/connection generation；独立 Desktop-owned 请求只读展示，不跨连接代答。

### R-11 现有 v2 registry、wire、SQLite、Cubit merge/alias/timestamp fallback 的删除清单

**Result: PASS（清单已建立；没有擅自删除）。**

- **Environment:** 当前源码树静态审计。
- **Exact commands/actions:** `rg -n 'conversation_sync_v2|runtime_overlay|conversation_mirror|_weavePreservedEntriesIntoCanonicalHistory|timestamp|fallback|clientMessageId' packages/bridge/src apps/mobile/lib`；逐段 `nl -ba`。
- **Raw evidence files:** [`raw/05-source-and-protocol-index.txt`](raw/05-source-and-protocol-index.txt)。
- **Source file and lines:**
  - Bridge registry/slot/wire：`packages/bridge/src/local-features/registry.ts:1-50`、`slots/conversation-sync-v2-protocol.ts:9-338`、`conversation-sync-v2.ts:562-730`。
  - Bridge canonical reader/mirror：`codex-bounded-history.ts:37-415`、`conversation-mirror.ts:93-317,1325-1504`。
  - Bridge legacy Desktop continuity：`slots/codex-desktop-continuity.ts:152-190,1145-1386`。
  - Mobile SQLite sync：`conversation_content_sync_service.dart:182-189,435-620`、`session_catalog_cache_repository.dart:1719-2277`。
  - Mobile v2 projection：`detached_timeline_projection.dart:32-128`；Cubit runtime fence `chat_session_cubit.dart:1596-1834`、v2 commit `6389-6448`。
  - Mobile legacy merge/weak alias：`chat_session_cubit.dart:6498-6504,6606-6844`；timestamp fallback `models/messages.dart:1235-1241`。
- **Observed behavior:** 当前是 additive v2 + mirror + continuity + legacy fallback 的叠加，不是物理上只剩一个 timeline writer；detached v2 有单独纯投影，但非 v2/旧路径仍保留 weave/弱 alias。
- **Interpretation:** v3 不能再继续在每层追加 alias；应先冻结 canonical provider item/turn identity，再逆序删除旧 writer/merge path。
- **Risk:** 误删 mirror/legacy 会破坏尚未迁移的 Claude/private 路径；不删则继续有重复写入者。
- **Recommended v3 decision:** 先做 source/provider matrix，再按 Bridge reader→wire→SQLite→Repository→Cubit→UI 逆序删旧路径，每次保留可回滚提交和链路测试。

### R-12 真实 Bridge → WSS → Dart decoder → SQLite → Repository → UI semantic receipt 是否已有可行测试链

**Result: FAIL（完整链未被当前仓库自动化证明）。**

- **Environment:** 代码/fixture 审计；没有生产或真实手机运行。
- **Exact commands/actions:** 审阅 `conversation-real-rollout.test.ts`、`conversation_content_sync_service_test.dart`、`protocol-wire.provenance.json`；尝试 `cd apps/mobile && flutter test ...`，本机结果为 `flutter: command not found`。
- **Raw evidence files:** [`raw/07-chain-coverage.txt`](raw/07-chain-coverage.txt)、[`raw/06-performance-and-tests.txt`](raw/06-performance-and-tests.txt)。
- **Source file and lines:** Bridge black-box [`packages/bridge/src/blackbox/conversation-real-rollout.test.ts:54-231`](<REPO>/packages/bridge/src/blackbox/conversation-real-rollout.test.ts:54)；Mobile service 架构注释 [`conversation_content_sync_service.dart:182-189`](<REPO>/apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:182)；SQLite transaction implementation [`session_catalog_cache_repository.dart:1719-2277`](<REPO>/apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart:1719)。
- **Observed behavior:** Bridge black-box 是真实 `BridgeWebSocketServer` + raw WSS，但需要本地 unredacted rollout/state DB；Mobile tests 是 sqflite_ffi + fake gateway；fixture provenance 明确说不证明 raw Codex normalization 或 physical iPhone。
- **Interpretation:** 目前没有一条测试同时跑真实 Bridge socket、Dart decoder、真实 SQLite、Repository、Cubit 和最终 Widget semantic receipt。
- **Risk:** 电脑端全绿不能拦住手机端实际的 decoder/commit/projection/UI 顺序错乱。
- **Recommended v3 decision:** 新增 headless Dart receiver，接真实 Bridge WSS；Provider 可用开发环境真实/固定 trace，但预期时间线由独立不变量 fixture 冻结，不能由实现代码生成。

### R-13 旧 pending 图片/消息是否还会在重挂接时静默自动发送

**Result: PASS（当前源码已禁止未确认记录自动重发）；实际旧设备状态 UNKNOWN。**

- **Environment:** 当前 Mobile source；未修改 SharedPreferences、未操作真实手机。
- **Exact commands/actions:** 审阅 `DraftService` 编码/解码、Codex session restore、`DurableSessionPreviewUpdater` callback 和 `ChatSessionCubit.sendMessage/retryMessage`。
- **Raw evidence files:** [`raw/08-outgoing-recovery.txt`](raw/08-outgoing-recovery.txt)。
- **Source file and lines:** `draft_service.dart:49-133`；`codex_session_screen.dart:1043-1148`；`codex_session_screen.dart:1970-2040`；`chat_session_cubit.dart:8020-8082,10768-10820`。
- **Observed behavior:** persisted pending record被恢复为 failed bubble；只有显式 retry 才调用 send/retry；已分发的相同 client ID 会被拒绝重复 dispatch。`initialSubmission` callback 只服务于新提交。
- **Interpretation:** 旧方案中“onLiveRuntimeReady 自动发送所有 pending”已经不在当前源码路径中。
- **Risk:** 设备上若仍安装旧 IPA，旧行为仍可能发生；本轮没有物理设备 build/日志证据。
- **Recommended v3 decision:** 保留当前 failed→explicit retry 状态机；补一个“旧 schema v1 pending 迁移后永不发网”的真实 headless/Widget 回归。

### R-14 现有真实链 fixture 是否代表当前 HEAD

**Result: FAIL（fixture provenance 的 Bridge head 不是当前 HEAD）。**

- **Environment:** 仓库静态文件；没有读取真实 rollout 正文。
- **Exact commands/actions:** `jq` 读取 `test-fixtures/conversation-chain/real-rollout.manifest.json`（只输出计数/哈希）；读取 `protocol-wire.provenance.json`。
- **Raw evidence files:** [`raw/07-chain-coverage.txt`](raw/07-chain-coverage.txt)；仓库 `test-fixtures/conversation-chain/*.json`。
- **Source file and lines:** `conversation-real-rollout.test.ts:48-76` 从 manifest 读取 source/state DB；`protocol-wire.provenance.json` 声明 `bridgeHead=7ec83bd...`，而当前 HEAD 为 `7db4efe...`。
- **Observed behavior:** fixture 是开发链样本，包含 126 v2 frame 的正式批次和不变量；但 provenance hash 不是当前 HEAD。
- **Interpretation:** fixture 可用于协议回归，但不能单独证明当前源码输出仍等价。
- **Risk:** 旧 fixture 通过会掩盖新代码改变；尤其不能把它当手机实际链路验收。
- **Recommended v3 decision:** 每次行为提交生成 source/dist hash + invariant snapshot；旧 fixture 标记 baseline，不覆盖 current-head proof。

## 2. 现有测试能证明什么、不能证明什么

已直接跑通的隔离 Bridge 定向测试：

- `conversation-mirror.test.ts` + `conversation-sync-v2.test.ts`：217 tests passed，0 failed，17.15 s。
- 隔离 synthetic benchmark：catalog、frame budget、bounded reader、normalizer 均有数据。

这些测试能证明：

- Bridge 的 v2 状态/目录/时间线协议有 page、ACK、revision、generation 和 frame budget 逻辑；
- SQLite service 的测试代码定义了 commit-before-ACK、staging、reset、retry 等不变量；
- detached projection 是 O(n) 的 canonical + outgoing + runtime 三层纯投影；
- pending submission 当前恢复为失败而非自动重发。

这些测试不能证明：

- Desktop 当前 build 与 daemon exact version；
- Desktop sidebar 是否自动出现 Bridge 新建/旧 thread；
- authenticated provider 的真实 turn/delta/completed/approval 通知；
- `thread/items/list` 在未来官方版本是否恢复；
- WSS 字节经过 Dart decoder 后的实际 SQLite commit 和 Widget semantic receipt；
- 物理 iPhone 上的加载、重连、滚动锚点和渲染结果。

## 3. v3 删除/收束建议（只列清单，本轮不删除）

### Bridge

1. 先冻结 `conversation-sync-v2-protocol.ts` 的 provider/source/thread/turn/item identity。
2. 用一个 provider adapter 取代同时存在的 `conversation-mirror`、`codex-bounded-history`、`codex-desktop-continuity` 内容合并入口；保留 continuity 只做运行状态/控制，不写 canonical content。
3. 迁移并验证后删除 `conversation-sync-v2.ts` 中 `externalCodexMonitors`、private rollout content observer 和 shared observer 对 canonical 内容的重复贡献；保留状态/authority event。
4. 删除 `session-catalog-monitor` 对 v2 catalog 的第二写入路径；只保留 v2 scheduler。
5. 将 `thread/items/list` capability probe 固化到 provider adapter，禁止每次失败重试同一不支持方法。

### Mobile

1. `ConversationContentSyncService` 只保留一个 WSS decoder、一个 staging/commit owner 和一个 `ConversationSyncCacheUpdate` receipt。
2. `conversation_mirror` 与 `conversation_content_sync` 的重叠 storage/wire 先做迁移表，再删旧 event handlers；不能并行写同一 cache window。
3. `detached_timeline_projection.dart` 保留为唯一 canonical/outgoing/runtime reducer。
4. `chat_session_cubit.dart` 中 `_weavePreservedEntriesIntoCanonicalHistory`、`_entryWeakKey`、`allowBroadLegacyAliases` 只允许在明确 legacy provider adapter 内存在；v3 detached/shared 路径删除。
5. 删除用显示 timestamp 作为排序兜底的路径；timestamp 只显示，不决定 provider 顺序。
6. 将 `DraftService` pending v1/v2 迁移为显式 outbox state；旧数据只产生 failed receipt。

### SQLite/测试

1. 保留 SQLite canonical mirror 为可重建副本，所有窗口更新必须经过 staging + atomic transaction。
2. 新增真实 WSS headless receiver；Widget 只验证最终 semantic receipt，不承担协议重放逻辑。
3. 每个 fixture 外置 expected invariant，禁止从 production reducer 生成 expected。

## 4. 决策表

| Decision | Result | v3 decision |
|---|---|---|
| Desktop shared switch | PASS 当前 env/UDS attach；FAIL exact version；UNKNOWN 首次切换重启语义 | 先对齐 Desktop bundled CLI 与 daemon 版本，再做 isolated restart gate |
| CLI same-daemon attach | PASS `codex resume --remote unix://PATH` help contract；TUI 实际 smoke UNKNOWN | 用 `resume --remote`，不用裸 proxy/stdio 假设 |
| Cold-thread immediate detection | FAIL fresh state `thread/started` 后立即 list=0；Desktop sidebar UNKNOWN | started/materialized/resumable/sidebar-visible 分状态 |
| Stable item identity | persisted page restart PASS；完整 lifecycle UNKNOWN；items/list FAIL | provider itemId/turnId canonical，fallback 必须 scoped/confidence 标记 |
| `clientMessageId` duplicate behavior | FAIL：app-server 创建两个 turn | Bridge ledger admission 是唯一幂等边界 |
| Cursor restart stability | PASS persisted cursor across daemon restart；FAIL immediate append visibility；compact UNSUPPORTED | revision commit 后才推进 canonical，compact 另做 provider fixture |
| Desktop unknown-thread discovery | app-server immediate list FAIL；Desktop GUI sidebar UNKNOWN | 用户观察 gate + state DB/materialization probe |
| Approval routing | Bridge-owned exact-generation PASS；Desktop-owned cross-connection UNSUPPORTED/禁止 | request 台账绑定 authority；独立 Desktop request 只读，不跨连接代答 |

## 5. 当前状态与下一步门禁

- 本轮没有源码行为修改、生产 Bridge 修改、Desktop 配置修改、真实会话写入、IPA/OTA/Cloud 发布。
- 调查新增的仅是本目录下的报告/原始证据文件，以及根目录填写的 `09-local-agent-report-template.json`；预先存在的 `notes/ccpocket-issues-mixed-fixed-and-unfixed_20260817.md` 未改动。
- 在 v3 实施前必须先补齐：
  1. exact-version Desktop/daemon isolated pilot；
  2. fake provider 的 approval/turn notification/unsubscribe 矩阵；
  3. real Bridge WSS → headless Dart → SQLite → Repository → Cubit semantic receipt；
  4. current-HEAD fixture regeneration；
  5. authenticated provider 下 compact/cursor/turn-item identity 真实证据。

没有证据的项目在本报告中保持 `UNKNOWN` 或 `UNSUPPORTED`，没有用“应该可以”代替结果。
