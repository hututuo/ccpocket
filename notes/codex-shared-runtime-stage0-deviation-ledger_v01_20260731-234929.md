# CC Pocket 共享 Codex 运行时 Stage 0 现场偏差台账

> 状态：`active`
> 适用分支：`feature/codex-shared-runtime-20260731`
> 权威母计划：`plans/codex-shared-runtime-warm-switch_v01_20260731-230240.md`
> 当前执行边界：只实施可回滚的共享 daemon 最小接入、隔离候选和自动预检；真实 Desktop/手机联动试验后恢复 private，并在用户确认前停止 Stage 3 及后续工作。

## 1. 现场身份与未触碰边界

- 源码 worktree：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-shared-runtime-20260731`
- 分支：`feature/codex-shared-runtime-20260731`
- 开工 HEAD：`20218b5c1866b3553133c95e94a42ae5923071be`
- 基线：`integration/mobile-session-sync-v2-20260730@a007dc712543c1410a26be980f2d838637c95c60`
- 开工时最新 `upstream/main`：`46b2de3585ae80aa8951b766397ea0ad020dfed9`，Bridge `1.69.6`
- 生产 Bridge：`1.69.5-compat.11.c64bf5ed`，唯一监听 `127.0.0.1:8765`，健康检查正常。
- 18765 没有本地 listener；现有 Tailscale Serve 已指向 `127.0.0.1:18765`，Pilot 不修改 Serve 或 VPN 配置。
- Desktop：`/Applications/ChatGPT.app`，内嵌 `codex-cli 0.146.0-alpha.9.2`，当前仍使用私有 stdio app-server。
- 本阶段禁止修改生产 8765、LaunchAgent、Mullvad/Tailscale、Mobile/Dart/SQLite、Swift、entitlement、Cloud、OTA、IPA 或 release task。

## 2. 偏差登记

| # | 母计划假设 | 当前一手证据 | 影响 | 本阶段采用的实现 | 验证门禁 |
|---|---|---|---|---|---|
| D01 | 可先用官方 standalone 安装器获得与 Desktop 完全相同的 daemon CLI。 | 目标 `codex app-server daemon` 只从 `$CODEX_HOME/packages/standalone/current/codex` 启动；空隔离 home 明确报缺少 managed standalone。将当前 Desktop 内嵌的 `0.146.0-alpha.9.2` 精确二进制放到该路径后，`daemon start/version/stop` 成功。公共安装器是否仍提供这一 alpha 精确版本未经证明。 | 直接跑安装器可能得到不同协议版本，使 Desktop 与 Bridge 连接同一 daemon 时出现不可解释偏差。 | Pilot 只使用当前 Desktop 内嵌精确 CLI 的隔离 managed 路径，不运行 `daemon bootstrap`，不把该方式提前宣称为正式升级方案。长期安装和自动升级留到用户确认后单独设计。 | daemon `version` 必须精确等于预期；CLI、socket、owner、权限任一不符即 fail closed；恢复后不得残留 pilot daemon。 |
| D02 | 第二客户端能立刻 `resume` 一个刚由第一客户端 `thread/start` 创建的线程。 | 精确目标二进制双客户端测试中，两个客户端都收到相同 `thread/started`，且都能 `thread/read`；但在首个真实 turn 产生 rollout 前，第二客户端 20/20 次 `thread/resume(excludeTurns:true)` 均返回 `no rollout found`，50 ms 重试仍失败。 | “卡片已全局发现”不等于“另一连接已能取得可写 attachment”。若把两者合并为一个成功条件，会产生重复 resume、假 Ready 或错误接管。 | 新线程首轮仍由创建连接发起并持有；Desktop 通过全局广播发现卡片。只有存在 durable rollout 后，第二连接才进行 adoption/resume 试验。UI/诊断分别报告 `discovered` 与 `attachable`。 | 自动合同测试固定覆盖 pre-first-turn gap；真实试验分别验证侧栏发现、首轮落盘、随后跨连接 read/resume。 |
| D03 | 需要修改或重签 Desktop 才能接入共享 daemon。 | 当前 Desktop `app.asar` 存在隐藏门 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`。在未强制 CLI、未指定自定义 CLI/command 时，它会调用 `codex app-server daemon version`，成功后以 UDS WebSocket 连接默认 socket；失败则静默退回 stdio。 | Pilot 无需改 ChatGPT.app，但必须证明它没有静默回退，否则“Desktop 已启动”会造成假阳性。 | 只提供可回滚的启动/恢复脚本：保存 GUI domain 原环境、临时设置 daemon 门、完整退出并重启 Desktop、验证私有 stdio 子进程消失且 UDS 确有 Desktop 连接。不得 patch 或重签 App。 | 进程树、socket 连接和 daemon 诊断三方同时成立；只看 Desktop UI 或 daemon 存在不算成功。恢复时精确还原原环境。 |
| D04 | 现有 `external` 或 `managed` transport 可直接承担 daemon 模式。 | 当前实现仅支持 TCP WebSocket；`managed` 会随 Bridge 关闭子进程；`external` 没有 UDS、版本/路径/权限校验。未知非空 mode 会被静默当成 `private`。 | 复用旧路径会破坏“Bridge 重启不终止 turn”和 fail-closed 边界，并可能在配置拼写错误时启动第二个 app-server。 | 新增独立 `daemon` mode、`CodexDaemonSupervisor` 和 UDS transport；保留旧三种模式兼容。未知非空值直接拒绝启动。Bridge 只验证并连接 daemon，绝不 start/stop/bootstrap 它。 | 单测覆盖旧模式、未知 mode、版本不符、socket 不安全、daemon 不可用、Bridge stop 后 daemon 存活。 |
| D05 | 普通 WebSocket 默认握手即可连接 daemon UDS。 | 精确 daemon 只接受 UDS 上的 WebSocket Upgrade；测试需要自定义 `createConnection`、URL `ws://codex-app-server/rpc` 且 `perMessageDeflate:false`。省略后者会收到 `Missing, duplicated or incorrect header sec-websocket-extensions`。 | 直接复用当前 `new WebSocket(url)` 必然失败或与 Desktop 行为不一致。 | UDS transport 固定禁用压缩并使用自定义 Unix socket 连接；不开放远程 TCP，不把 socket 路径暴露给手机。 | 真实目标 daemon 握手、initialize 和 `thread/list(useStateDbOnly)` 通过；错误扩展合同有回归测试。 |
| D06 | 当前 `CodexProcess` 的 resume 已可安全附着 Desktop 活跃线程。 | 当前 bootstrap 会附带 `cwd`、配置、权限、模型等候选字段，并在 RPC 返回后无条件 `setStatus("idle")`；它没有处理 `thread/status/changed`。 | 观察动作可能覆盖 Desktop 线程设置，并把真实 active/attention 错投影成 idle；这与用户已观察到的“外面 Working、里面不运行”一致。 | 新增严格 observer/adoption attach：只发 `{threadId, excludeTurns:true}`，解析返回的 `thread.status`/active turn，并处理后续状态通知。普通 Bridge 新建/恢复路径保持原语义。 | 精确断言 observer resume 参数；active、waiting、systemError、unknown 均不得被无条件 idle 覆盖。 |
| D07 | 当前通知/请求路由已适合多客户端共享 daemon。 | 当前普通通知按 threadId 过滤，但 server-initiated request 在进入 `handleServerRequest` 前没有同等线程过滤；不支持的方法会立即回 `-32601`。 | 多 attachment 时可能由错误 Bridge session 响应 Desktop 所属审批/问题，或多个 session 同时响应同一请求。 | Pilot 现已同时校验 thread、runtime generation 和由 exact attachment 成功启动的 turn；完成/停止/换代清除所有权，adopted/Desktop turn 与 steer 均 fail closed。完整 Action Broker、持久请求台账与 Desktop 侧 first-responder 仲裁仍属于 Stage 3+。 | 交错请求测试覆盖 foreign thread、Desktop turn、本 attachment turn、完成后迟到请求和旧 generation；用户 Pilot 仍禁止工具/审批/问题/current-time。 |
| D08 | 当前 WebSocket transport 的排队语义足以应对共享连接。 | `isRunning` 在仍连接中即为 true，任意 envelope 会无界进入内存 queue；断线/重连没有公开 connection generation。 | mutation 可能在身份与连接代次不明确时迟到发送；旧连接返回可覆盖新状态。 | daemon transport 只允许初始化握手的有界启动队列；业务 mutation 在 ready 前 fail closed。每次连接建立 generation，旧 generation 数据直接丢弃。 | 断线、socket 替换、迟到帧和队列边界测试；不得出现跨代 mutation 重放。 |
| D09 | `thread/start` 广播即可证明 Desktop 项目侧栏完整联动。 | 两客户端协议测试只证明全局 `thread/started`、loaded/read；Desktop 静态代码会 observe/upsert，但项目 assignment、标题异步更新、排序和真正可见卡片尚无设备证据。`thread/resume` 也不产生新的 `thread/started`。Desktop 的 assignment、catalog cache、renderer store 和 sidebar order 是独立层；当前 catalog 还标记为未完成。 | 只验证 RPC 会夸大产品完成度，尤其是“未知旧 thread 继续后自动进正确项目”。若 Desktop 使用 `updated_at` 排序，也不能错误要求 manual order map 必有记录。 | Pilot 将“广播收到”“Desktop store 观察”“正确项目侧栏可见”“标题/排序稳定”“旧 thread 继续发现”拆成独立验收项，并先记录 Desktop 实际 sort mode。未知旧 thread 不提前声明 capability。显式 auto-open 只把现有 `codex://threads/<threadId>` 当候选实测，不作为后台补救。 | 用户实际观察 Desktop 侧栏；截图/日志与 threadId 对照；失败时只修最小发现闭环，不进入后续阶段。auto-open 必须同 PID、同 threadId、无 fork、无重复导航。 |
| D10 | 实施可立即扩展到 Mobile、队列、通知和发布。 | 当前目标是先验证共享 daemon 是否真正解决 Desktop ↔ Bridge 同线程实时联动；Mobile 现有 `conversation-sync-v2`、缓存和兼容线已经复杂，提前修改会扩大变量。旧 Mobile 对未知 server message type 会转成错误消息，而不是静默忽略。 | 一旦试验失败，将无法区分 daemon、Bridge attach、Desktop 展示还是 Mobile reducer 的根因；无门控的新消息还会直接伤害旧客户端。 | Stage 0–2 不改 Mobile/SQLite/Swift/通知。候选只在 `127.0.0.1:18765` 和隔离数据运行，使用 Bridge 测试客户端。未来新增 settings/presentation 消息必须 capability/subscription gated；旧客户端缺 intent 等价 `none`。真实试验后恢复 private 并等待用户确认。 | `git diff` 不含 Mobile/native；生产 8765 PID、入口、配置与健康不变；旧协议回归不得收到未知消息。 |
| D11 | 最新 upstream 可以机械覆盖本地兼容线。 | `upstream/main@46b2de35` 与本地冲突集中在 package/lock/changelog/README；源码新增 Luna assist/命名优化，Mobile release metadata 和版本变更可自动三方合并。 | 整文件取 theirs 会丢失 compat.11 以来的本地协议、发布记录和 GPL 元数据；跳过 upstream 又会在旧基线上开发。 | 在 feature 线创建正常 merge commit，语义保留两侧；Bridge 候选版本单调升级为 `1.69.6-compat.12`。不把 upstream Mobile build 号当作本轮 IPA 发布。 | merge-tree 审核、目标源码测试、package/lock 一致、上游 Luna 行为与本地兼容测试同时通过。 |
| D12 | 候选 Bridge 只改成 18765 就足以与生产隔离。 | 多个 store 仍固定落到 `$HOME/.ccpocket`，Firebase/push 会在启动路径初始化；旧 candidate launcher 还会复制生产 plist 环境。真实 `~/.codex` 约 37 GiB，不能复制来制造“隔离”。 | 只换端口仍会污染生产 Bridge 身份、队列、凭据、文件状态或 Cloud；完整复制 Codex home 又会浪费空间并复制权威历史。 | 候选使用短的 0700 `/private/tmp/cp-<nonce>` 根、独立 HOME/CODEX_HOME/项目/Bridge state、随机 API key、禁用 mDNS/自动 artifact/push/Cloud。新增明确的 fail-closed push kill switch后才允许启动 18765。认证只采用经授权的最小 0600 材料，不复制 sessions/SQLite/history。 | 启动前测试所有可写路径与生产分离；候选退出后生产 store/hash/PID不变；无外部 push/Cloud 请求；socket 路径在 macOS Unix 长度上限内。 |
| D13 | 当前 login shell 的 Node/npm 可直接作为候选构建环境。 | 仓库和 CI 固定 Node 22，而当前生产进程和普通 shell可使用 Node 26；根 `npm ci` 的 prepare 还会写共享 Git hooks。 | 漂移工具链会制造不可归因的构建差异；linked worktree 的 hooks 并不隔离。 | 构建/测试固定仓库声明的 Node 22.23.1，并采用不运行共享 prepare hook 的隔离安装策略；候选另在目标运行 Node 上做 smoke。不得借用其他 worktree 的 `node_modules` symlink。 | 记录精确 Node/npm 版本；lockfile 安装可复现；共享 hooks 前后 hash 不变；Node 22 测试与目标运行时 smoke 均通过。 |
| D14 | 多连接共享只需要修正 thread notification 过滤。 | 目标 app-server 会把同一 server request 发给多个订阅连接，第一个响应消费回调；后续响应不再命中。external current-time 功能还要求恰好一个订阅者。 | Desktop 与 Bridge 可能竞争审批/问题响应；仅依靠 threadId 仍可能双答。开启不兼容的 current-time provider 会使共享拓扑失效。 | Pilot 默认 observer，只对一个明确 thread、单 actor、短时开启写 canary；请求处理同时校验 thread、turn、connection generation 和本地写门。检测到 external current-time 或无法证明请求所有权时拒绝共享写试验。完整 request ledger/Action Broker 留到 Stage 3+。 | 双客户端 pending request/first-responder 合同测试；非 owner attachment 零响应；不兼容 capability 明确 fail closed。 |

## 3. 精确目标协议快照

从当前 Desktop 内嵌目标 CLI 生成 schema 并实测确认：

- 目录/状态：`thread/list(useStateDbOnly, sortKey)`、`thread/loaded/list`、`thread/read`、`thread/status/changed`。
- 附着/历史：`thread/resume(excludeTurns, initialTurnsPage)`、`thread/turns/list(itemsView)`、`thread/items/list`。
- 写操作：`thread/start`、`turn/start(clientUserMessageId)`、`turn/steer(expectedTurnId, clientUserMessageId)`。
- 请求生命周期：server request 与 `serverRequest/resolved`。
- `thread/started` 为全局广播；线程内实时通知为订阅连接范围。
- 当前 Desktop 内嵌 CLI 与 `/opt/homebrew/bin/codex` 均报告
  `0.146.0-alpha.9.2`，现场 SHA-256 均为
  `68474c6192406b8a0278243c8283b87a84798a69fb498f30c3715861f8082542`。

这些事实只对当前目标 `0.146.0-alpha.9.2` 和本次实际测试负责。正式切换前仍须对当时 Desktop/Codex 版本重新生成 schema 和运行合同测试。协议语义参考官方 [app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) 与 [daemon README](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)，但目标二进制实测优先于 main 分支推断。

## 4. Stage 0–2 实施收束

本阶段只允许形成以下可回滚提交：

1. 记录现场偏差和试验边界。
2. 语义接入最新官方 1.69.6，并将候选版本升为 `1.69.6-compat.12`。
3. 增加 daemon 严格配置、supervisor 和 UDS transport。
4. 增加 observer/adoption attach、状态保真、请求隔离和最小诊断。
5. 增加不修改 ChatGPT.app 的可回滚 Desktop pilot 脚本与说明。

自动预检通过后才进入真实试验。真实试验默认执行顺序：

1. 确认生产 8765 无变化并记录回滚基线。
2. 启动隔离 daemon 与 18765 候选 Bridge。
3. 一次性完整退出 Desktop，临时启用本地 daemon 门并启动。
4. 验证 Desktop 连接 UDS 且无私有 stdio app-server。
5. 分别验证新 thread 发现、首轮落盘、后续同 thread 实时、标题/项目/排序、Bridge 重启不终止 daemon turn。
6. 手机只连接隔离候选；不替换生产服务。
7. 停止候选，精确恢复 Desktop 原环境和 private 模式，确认私有 app-server 恢复。
8. 向用户汇报证据并停止，等待明确确认。

截至 2026-08-01，步骤 1–2 的自动部分已经完成：隔离 daemon、18765
候选、双 Bridge 客户端、真实 canary、无 turns 回放的中性 resume、
Bridge-only restart 和 active-turn re-attachment 均通过。完整证据见
`notes/codex-shared-runtime-stage2-pilot-evidence_v01_20260801-014302.md`。
Desktop GUI 环境尚未改变，因此步骤 3–8 仍是当前硬门。

## 5. 尚未验收的事实

- 当前 Desktop 是否把 Bridge 新建 thread 立即放入正确项目侧栏。
- Desktop 与 Bridge 两个真实订阅连接之间的 `resume`、实时事件和审批
  行为；两个 Bridge 测试客户端已通过，但不能替代 Desktop。
- Desktop 与 Bridge 同时对一个 active thread 发 mutation 时的官方冲突语义。
- app-server daemon 重启后的 active turn 和 pending request 恢复上限。
- 正式 standalone 安装、升级和回滚方式。
- Mobile、通知、队列、持久绑定、性能审计、生产 warm switch、IPA 与物理设备验收。

以上任一项未完成时，都不得把“共享 Codex 运行时”标记为完整产品功能。
