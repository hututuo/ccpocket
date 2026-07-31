# CC Pocket 共享 Codex 运行时与温和切换实施纲领

> 状态：`draft`，待用户复核本次完整修订后执行。
> 修订原则：以用户提供的 657 行原计划为母版，保留原有架构、接口、故障模型、兼容矩阵、测试、性能、部署和回滚要求；本版只重排实施节奏，并补充 Bridge ↔ Codex Desktop 真实联动试验。
> 强制停点：完成共享端最小接入和自动预检后，必须由用户参与验证 Desktop 侧栏/会话行为；用户确认前不得继续全量迁移、生产发布或 stable。

## 一、目标、执行顺序与当前结论

### 1. 最终目标

将目前“两套独立 app-server 共享历史文件”的结构，改成：

```text
同一个独立 Codex app-server daemon
          ├── Codex Desktop
          └── CC Pocket Bridge
                    ↓
          conversation-sync-v2
                    ↓
             Mobile SQLite/UI
```

完成后应满足：

- Desktop 发起的 turn，手机实时显示状态、增量、工具、审批和最终结果。
- 手机发起的 turn，Desktop 无需重启即可在同一权威线程中发现、查看和继续使用。
- Bridge 新建的持久会话自动加入或更新 Desktop 侧栏，并进入正确项目；不能只证明 thread 能按 ID 读取。
- 默认只更新 Desktop 侧栏，不抢焦点；用户可选择在能力可用时自动打开对应会话。
- Bridge 更新或重启只断开自己的连接，不终止正在运行的 Codex turn。
- 所有持久会话继续本地优先打开，不恢复“点击后激活”的旧模式。
- Bridge 统一处理发送、排队、引导、审批、设置和重连，不再让 Desktop 路径与 Bridge 路径各写一套业务逻辑。
- 旧 Mobile、旧 Bridge、private 模式和 Claude 路径继续兼容。
- 不以高频 JSONL 扫描、隐瞒 unknown、重复 resume 或自动退回 private 换取表面可用。

### 2. 本次修订后的强制实施顺序

1. 在独立 worktree/分支中工作，绝不直接修改当前集成工作树。
2. 先实现最小可用 shared daemon：独立 daemon、Bridge UDS transport、Desktop 可回滚接入和关键状态修正。
3. 先在隔离环境自动验证，再把候选 Bridge 与真实 Desktop 临时接到同一 daemon。
4. 暂停后续实施，由用户按我给出的操作步骤进行真实联动试验。
5. 重点确认：Bridge 新建/继续会话能否在不重启 Desktop 的情况下自动出现在正确项目侧栏、更新状态并继续使用。
6. 试验失败则只修共享端最小闭环并重试，不提前铺开 Mobile、队列、通知和发布改造。
7. Pilot 前先在 feature 线语义合入当时最新 upstream；用户确认联动体验后，只吸收 pilot 期间新增的 upstream 提交并复验，然后继续 action broker、持久恢复、Mobile、性能审计和最终部署。

这里的“不需要重启 Desktop”指：首次从 private 切换到 shared daemon 时允许且必须完整退出并重新启动 Desktop 一次；完成一次性切换后，后续 Bridge 新建或继续会话不得要求再次重启 Desktop。

### 3. 2026-07-31 修订时现场快照

| 项目 | 当前状态 |
|---|---|
| 计划实施 worktree | `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-shared-runtime-20260731`，已从权威集成线创建 |
| 计划实施分支 | `feature/codex-shared-runtime-20260731@a007dc712543c1410a26be980f2d838637c95c60`，创建后尚未改源码 |
| 权威源码基线 | `integration/mobile-session-sync-v2-20260730@a007dc712543c1410a26be980f2d838637c95c60` |
| 生产 Bridge | `1.69.5-compat.11-c64bf5ed`，PID 11545，唯一监听 `127.0.0.1:8765` |
| Bridge 模式 | `private`；当前 health 为 ok，修订时 sessions=0、clients=0 |
| Desktop | `26.727.40816 (6067)`，内嵌 Codex `0.146.0-alpha.9.2` |
| Desktop app-server | PID 97079，为 Desktop PID 97029 的独立 stdio 子进程，不与 Bridge 共用运行时 |
| 官方 daemon | standalone、daemon state 和 control socket 均不存在 |
| 本地 upstream 跟踪 ref | `46b2de3585ae80aa8951b766397ea0ad020dfed9` / Bridge 1.69.6；实施开工必须重新 fetch |
| 生产判断 | 当前保持 compat.11/private，尚不允许切共享模式 |

上述 PID、版本、上游 HEAD、手机在线状态和运行任务都会漂移。每次切换前必须重新取证，不得把本表当永久事实。

根因不是“历史不同步”，而是 Desktop 和 Bridge 各自持有一个 app-server。它们虽然写同一套状态数据库和 rollout，但实时 turn、审批、设置与连接内状态彼此不可见。

官方 app-server 已支持 Unix socket、线程状态、`thread/resume(excludeTurns:true)`、历史分页、pending request 重放和多连接订阅；TCP WebSocket 仍标注为实验性，因此正式方案使用 Unix socket，不扩展现有 `managed/external` TCP 路径。[官方 app-server 协议](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)、[daemon 生命周期](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)。

需要区分两个协议事实：

- `thread/start` 会产生没有 connection filter 的 `thread/started` 广播，所有已初始化的同 daemon 连接理论上都能收到。
- `thread/resume` 会把请求连接 attach 到 thread 并返回快照，但不会再次广播一个新的 `thread/started`。

对应上游实现证据见 [thread/start](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/thread_processor.rs#L1375-L1449)、[broadcast message](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/outgoing_message.rs#L574-L599)、[transport fan-out](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/transport.rs#L214-L228) 和 [thread/resume](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/thread_processor.rs#L3304-L3456)。当前 Desktop 的处理证据来自本机 [app.asar](/Applications/ChatGPT.app/Contents/Resources/app.asar)，实施时必须按实际安装版本重新复核。

因此，Bridge 新建 thread 被已运行 Desktop 自动发现有较强的协议与当前 Desktop 代码依据；Bridge 续用一个 Desktop 已知 thread 应更新原条目；而“Desktop 已经运行、但从未知道这个旧 thread，仅靠 Bridge resume 就自动插入侧栏”没有稳定协议保证，必须作为独立试验项，不能提前宣称成立。若试验失败，不得广告 `codex_desktop_unknown_resume_discovery_v1`；完整产品目标要求实现受支持的目录失效/发现机制并通过实测，除非用户明确缩小“继续会话自动出现”的范围。

本机 Desktop 静态代码已经确认：主进程会向窗口转发 app-server 通知，renderer 收到 `thread/started` 后会 upsert conversation，`thread/status/changed` 也会更新状态。因此 Bridge 通过同一 daemon 新建线程后，理论上无需重启即可进入 Desktop store。静态证据不能代替真实侧栏验收；项目归属、sidebar order、标题异步更新和是否立即重绘仍必须实测。

## 二、固定架构与公共接口

### 1. 运行时职责

新增四个清晰边界：

- `CodexDaemonSupervisor`
  - 检查 standalone、daemon 版本、socket、PID、权限和健康。
  - Bridge 关闭时绝不停止 daemon。
  - 生产只接受已经运行且版本匹配的 daemon。

- `CodexSharedRuntimeCoordinator`
  - 保持一条只读控制连接，接收全局 `thread/status/changed`、读取目录和配置。
  - 按需维护每线程独立 UDS 连接，避免重写 JSON-RPC ID 和审批路由。
  - 保证同一 `(codexSourceId, threadId)` 在 Bridge 内只有一个可变 attachment。

- `CodexActionBroker`
  - 统一处理新 turn、steer、interrupt、审批、问题回答、设置和 Goal。
  - 提供 per-thread 串行锁、generation fence、结果回执和冲突冻结。
  - Bridge-local fence 不能冒充官方 writer lease；Desktop 并发风险由发布门禁控制。

- `CodexRuntimeBindingStore`
  - 原子持久化 attachment、单槽队列和 delivery receipt。
  - 默认路径 `~/.ccpocket/codex-runtime-bindings-v1.json`，目录 0700、文件 0600。
  - 以 `codexSourceId + threadId` 为键，不以标题、Bridge session ID 或 IP 为权威身份。

### 2. Bridge 配置

新增正式模式：

```text
BRIDGE_CODEX_APP_SERVER_MODE=daemon
BRIDGE_CODEX_DAEMON_CLI=<standalone codex 绝对路径>
BRIDGE_CODEX_DAEMON_SOCKET=<Unix socket 绝对路径>
BRIDGE_CODEX_DAEMON_EXPECTED_VERSION=<精确版本>
CODEX_HOME=<明确的权威 Codex Home>
```

规则：

- `daemon` 模式只连接 Unix socket。
- socket 未配置时默认解析为 `$CODEX_HOME/app-server-control/app-server-control.sock`。
- daemon 不可达、版本不符、socket 权限异常或协议合同不满足时，Codex 写操作 fail closed。
- 禁止从 daemon 静默退回 private，避免同一线程出现两个 app-server。
- 未设置 mode 时仍默认 private，保留旧安装兼容。
- 非空但未知的 mode 必须启动失败，不能像当前代码一样悄悄当作 private。
- `managed/external` 保留为实验兼容，不作为正式生产路径。
- 不使用 `codex app-server proxy`；Bridge 与当前 Desktop 一样，直接通过 Unix socket 完成 WebSocket Upgrade。

试验阶段另加默认关闭的 canary 门禁：

```text
BRIDGE_CODEX_SHARED_PILOT=1
BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START=0|1
BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START=0|1
```

- 第一项只允许明确测试环境接入 shared daemon。
- `ALLOW_THREAD_START` 只控制 `thread/start`，用于验证 Desktop 新线程发现。
- `ALLOW_TURN_START` 只控制已有 thread 内的 `turn/start`，用于验证实时 turn；两项必须分别授权、分别记录事件和结果。
- 两项都只在隔离 canary、单 actor、无并发时临时开启，不等于生产 `writable`，不得绕过后文的双客户端并发门禁。

### 3. 新增能力与状态字段

新增 capability：

```text
codex_shared_runtime_v1
codex_action_broker_v1
runtime_diagnostics_v1
codex_desktop_sidebar_sync_v1
codex_desktop_unknown_resume_discovery_v1
codex_desktop_auto_open_v1   # 仅在安全导航能力实测可用时声明
```

在 `ConversationSyncV2Status` 增加可选字段，旧客户端可忽略：

```text
executionHost:
  bridge | desktopAppServer | unknown

activeTurnId:
  string | absent

controlState:
  readOnly | steerable | writable | reconciling | blocked | unavailable

authorityGeneration:
  opaque string
```

现有字段不增加新枚举：

- `source` 继续表示证据来源，daemon 权威事件仍为 `appServer`。
- 共享 daemon 中真正执行 turn 的物理 host 是 daemon；`executionHost` 是为兼容现有 Mobile 已落地字段而保留的“发起方投影”，内部新代码统一命名为 `turnOrigin: bridge | desktop | unknown`，不得据此暗示仍有两个执行 app-server。
- `runtimeAttachment` 在共享 daemon 中为 `loaded`。
- `ownedElsewhere` 只保留给真正的 legacy 独立 app-server。
- `executionHost` 由 turn 启动 RPC 关联判断：
  - Bridge 发起并确认的 turn：`bridge`。
  - 未匹配 Bridge 启动请求的 peer turn：`desktopAppServer`。
  - 关联不完整：`unknown`，不得猜测。
- idle 会话不显示 Ready，也不显示电脑/Bridge 主机图标。

操作请求继续使用现有消息类型，但增加：

```text
authorityGeneration
expectedTurnId
clientMessageId
presentationIntent:
  none | applyMachinePolicy
presentationRequestId:
  opaque id | absent
```

`presentationIntent` 属于 Mobile/测试客户端发给 Bridge 的显式用户动作 envelope，不直接透传给 app-server：

- 用户明确新建、继续或点击“在 Desktop 打开”时使用 `applyMachinePolicy`，并携带幂等 `presentationRequestId`。
- 内部 attach/resume、reconcile、预热、重连、审批恢复、queue drain 和旧客户端缺字段时一律视为 `none`。
- `presentationRequestId` 只保证展示动作最多一次，不替代 `clientMessageId` 或 thread/turn 身份。
- 机器策略为 `autoOpen` 也不能让缺少显式 intent 的旧 Mobile 请求自动打开 Desktop。

回执统一为：

```text
acceptedByBridge
queued
providerAccepted
providerRejected
outcomeUnknown
reflectedInHistory
```

UI 语义：

- 没有排队时，消息只在 provider 接受后显示普通发送勾，不出现“已在本地排队”。
- 真正排队时，队列卡片第一勾表示 Bridge 已持久化，第二勾表示 provider 接受或已在权威历史中反映。
- daemon 断线期间的审批、steer、interrupt、settings 不自动重放。
- 普通 input 只有在身份、generation、status 和历史对账完成后才可能重放。

### 4. Desktop 展示策略

按已认证 `bridgeInstanceId` 对应的 Mac 保存，不按 thread、手机、IP 或账号全局保存：

```text
desktopPresentationPolicy:
  sidebarOnly | autoOpen
```

默认 `sidebarOnly`：

- Bridge 新建或继续会话后，Desktop 侧栏自动新增或更新对应 threadId；在线 Desktop 对未知旧 thread 的继续能力由独立 capability 和硬门控制，不能混在普通 sidebar capability 中。
- 不抢焦点，不改变 Desktop 当前页面。
- 标题从占位值变为正式标题时只更新同一 threadId，不生成第二张卡。
- 必须验证线程进入正确项目的 assignment 和 sidebar order；底层 thread 可读、全局置顶可见或能深链打开，均不能替代项目侧栏验收。

可选 `autoOpen`：

- 只响应用户在手机上明确执行的新建、继续或“在 Desktop 打开”。
- 后台同步、通知、状态心跳和目录刷新不得抢焦点。
- 必须按 threadId 导航，不按标题、cwd 或时间匹配。
- 重复请求合并并设置冷却，避免连续切页。
- 只有当前 Desktop 版本存在稳定、可调用、可验证的本地导航接口时才声明 `codex_desktop_auto_open_v1`。
- 若没有受支持的接口，禁止修改或重签官方 App，也不依赖脆弱的私有 IPC/UI 自动化；Mobile 禁用该选项并明确显示“当前 Desktop 版本只支持侧栏联动”。一次点击打开本身也需要受支持的导航能力，不能被当成无条件 fallback。

`codex_shared_runtime_v1`、sidebar sync 和 auto-open 三项能力必须分开广告；共享 daemon 成功不能冒充 Desktop UI 联动全部完成。

试验阶段先由 Bridge 测试客户端或本机诊断命令携带明确 presentation intent，验证能力后再做 Mobile 设置 UI；现有 Mobile 缺少新 intent，不能用来证明 auto-open 安全性。正式配置响应包含 `supportedPolicies/configuredPolicy/effectivePolicy/revision`，setter 携带 `requestId + expectedRevision` 并返回 canonical ACK；未知值、旧版本或解析失败时安全回到 `sidebarOnly`。这样第一次联动试验原则上不需要新 IPA。

机器设置使用独立 `DesktopPresentationSettingsStore`，默认路径 `~/.ccpocket/desktop-presentation-settings-v1.json`：

- 目录 0700、文件 0600，临时文件写入、fsync、原子 rename；
- revision 跨 Bridge 重启单调持久；
- 损坏文件原样隔离留证，不以空文件覆盖，effective policy 回到 `sidebarOnly`；
- 不能写进每线程 binding store、Mobile SharedPreferences 或 `status_json`；
- wire 消息为 `desktop_presentation_settings_snapshot`、`desktop_presentation_settings_update`、`set_desktop_presentation_policy` 和 `desktop_presentation_policy_ack`；
- Desktop 版本/动态能力变化时允许 `configuredPolicy=autoOpen`、`effectivePolicy=sidebarOnly`，Bridge 必须主动 update Mobile 并给出结构化原因。

presentation 是 thread 创建/续用成功后的次要效果。打开 Desktop 失败只能报告独立 `presentationFailure`，不得回滚、重复提交或重新创建 turn。

### 5. 健康接口

保留兼容 `/health`，新增：

- `/livez`
  - 只判断 Bridge 进程是否存活。

- `/readyz`
  - daemon mode、版本、socket、initialize、source、reconcile、split-brain 均正常才返回 200。
  - 否则返回 503。

- 认证后的 `/diagnostics/runtime`
  - Bridge/runtime SHA、PID、启动时间；
  - desired/effective mode；
  - daemon 版本、PID/boot identity、socket owner/mode；
  - control connection 和 thread attachment 数；
  - active turn、queue、pending approval、last reconcile；
  - generation、gap、fallback 和 maintenance 状态；
- Desktop 进程是否按预期启动、是否存在私有 stdio app-server，仅作为本机拓扑诊断；
  - 不输出 token、正文、完整路径或审批敏感内容。

公开 app-server 当前没有 subscriber-presence API，因此诊断不得把 capability、`thread/loaded/list`、socket 存在或 Desktop 进程存在写成“Desktop 正在查看此线程”。真实 Desktop 侧栏/窗口行为必须由 UI 试验确认。

## 三、实施阶段与具体代码改动

### 阶段 0：独立实施线、现场复核与试验隔离

已经建立：

- worktree：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/codex-shared-runtime-20260731`
- 分支：`feature/codex-shared-runtime-20260731`
- 起点：`integration/mobile-session-sync-v2-20260730@a007dc712543c1410a26be980f2d838637c95c60`
- 预留的最终集成线名称：`integration/codex-shared-runtime-v1-20260731`；真实试验和用户确认前不得创建或合并该分支

开工必须：

1. 验证 worktree 绝对路径、分支、HEAD 和 clean 状态。
2. fetch 最新 `upstream/main`；当前本地跟踪 ref 为 [46b2de3](https://github.com/K9i-0/ccpocket/commit/46b2de3585ae80aa8951b766397ea0ad020dfed9)，但不把这一快照当未来事实。
3. 在 feature worktree 内先语义合入开工时最新官方代码，形成独立提交；不用本地整文件覆盖上游，不创建或合并 integration 分支。
4. Pilot 必须在未来准备继续实施的真实最新基线上执行，避免用户先验收旧基线、上游合入后又改变关键行为。
5. 重新检查 Desktop 版本、内嵌 CLI、standalone、daemon、Bridge runtime、LaunchAgent、Mobile build、当前活动 turn 和发布通道。
6. 用目标 Codex 二进制临时生成 schema，确认：
   - `thread/list`
   - `thread/read`
   - `thread/resume(excludeTurns)`
   - `thread/turns/list`
   - `thread/items/list`
   - `thread/status/changed`
   - `thread/settings/updated`
   - `serverRequest/resolved`
   - `turn/steer(expectedTurnId)`
   - `clientUserMessageId`
7. 建立“原计划假设 → 当前源码/运行证据 → 偏差 → 等价实现 → 验证”台账。
8. 明确试验线程、CODEX_HOME、候选端口和回滚点；不得用用户正在运行的重要 turn 做故障注入。

### 阶段 1：最小共享端 pilot

这一阶段只实现足以验证 Bridge ↔ Desktop 共用同一 daemon 的最小闭环，不提前铺开全部 Mobile、持久队列和生产部署。

Pilot 明确不修改 `conversation-sync-v2`、Dart decoder、SQLite、Mobile UI、Shorebird、IPA、Swift、entitlement、通知 category 或原生插件。触发 start/resume 优先使用 Bridge 测试客户端；若现有 Mobile 能兼容连接 candidate，也无需更新手机。

#### 1.1 独立 daemon

使用官方 standalone installer 安装精确版本，不使用 `latest`，记录 installer 与二进制 SHA。

不运行 `daemon bootstrap`：

- bootstrap 会安装定时更新器，更新后可能直接重启 app-server；
- 当前 updater 没有 active-turn drain，不能用于生产。[官方 daemon README](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)

Pilot 只使用可回滚的测试 daemon 启动方式，不安装永久 keeper。试验前先在隔离 `CODEX_HOME` 和 socket 验证，只有合同通过才允许触及真实 Home。

用户确认 pilot 后才新增独立 LaunchAgent：

- `com.ccpocket.codex-app-server-keeper`
- `RunAtLoad=true`
- 使用周期性幂等 `daemon start` 健康恢复；
- 不使用 `KeepAlive` 包裹会立即退出的 `daemon start`；
- 不负责自动下载或更新二进制；
- 生命周期与 `com.ccpocket.bridge` 完全分离；
- 带 desired-mode/inhibit fence，回滚时不会把已禁用的 daemon 自动拉起。

#### 1.2 Desktop 可回滚接入

当前 Desktop 26.727 的隐藏本地 daemon 门禁已经在本机包中确认。启用条件包括：

- `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`
- `CODEX_APP_SERVER_FORCE_CLI != 1`
- 没有 `CODEX_CLI_PATH`
- 没有自定义 CLI command
- 没有 bundled git
- `daemon version` 探测通过且版本满足要求

Pilot 使用独立、可回滚的 Desktop 启动入口传入环境，不先永久修改登录域：

- 不修改、不重签 ChatGPT.app；
- 不能只把环境变量写进 daemon/keeper 的 LaunchAgent，因为那不会自动注入 ChatGPT；使用 GUI launchd domain 的临时 `launchctl setenv/unsetenv` 或直接受控启动，并记录恢复步骤；
- 不使用会影响其他应用的长期全局环境残留；
- 保存普通启动方式作为立即回滚；
- 初次切换前完整退出 Desktop，确认 private stdio 子进程退出，再以 daemon 模式重新打开；
- 每次 Desktop 更新后重新审计隐藏门禁。

当前门禁探测有时间上限并可能静默退回 stdio。因此每次启动都必须以进程父子关系、socket 连接、daemon PID/boot identity 和版本证明 Desktop 实际接入 shared daemon，不能只看环境变量已设置。

用户确认试验后，持久化只能采用两种已验证方式之一：受控 Desktop launcher；或登录后执行 GUI-domain `launchctl setenv` 的一次性用户 job。该 job 必须保存/恢复原值、可卸载，并在重新登录后复验；不能把另一个 LaunchAgent 自己的 `EnvironmentVariables` 误当成对 ChatGPT 生效。

#### 1.3 Bridge daemon mode 与最小 transport

重点修改：

- `packages/bridge/src/codex-app-server-config.ts`
- `packages/bridge/src/codex-transport.ts`
- 新增 `codex-daemon-supervisor.ts`

Transport 最小状态：

```text
disconnected
→ connecting
→ connected
→ disconnected(retryable)
→ fatal / closedByOwner
```

约束：

- 使用 `ws://localhost/rpc` 加 Unix `net.createConnection(socketPath)`。
- 校验 socket 为 Unix socket、当前 uid 所有、父目录安全、路径属于当前 `CODEX_HOME`。
- 不在 transport 内缓存并盲发 JSON-RPC。
- `-32001 Server overloaded` 只对可证明幂等的读请求做指数退避与 jitter。
- 已发但结果未知的 mutation 标记 `outcomeUnknown`。
- 旧 connection generation 的所有迟到 frame 直接丢弃。
- Bridge shutdown 只关闭自己的连接，不调用 daemon stop。
- daemon mode 不可用时明确 degraded/fail closed，不创建 private fallback。

#### 1.4 Pilot 必须先修的共享语义

即使完整 Coordinator 尚未完成，也必须先修正以下阻塞项：

- `thread/resume` 解析真实 status 和 active turn，不能无条件设成 idle。
- observer attach 不发送 model、effort、sandbox、approval policy、writable roots 或 profile。
- server request 与 notification 都按 threadId 过滤。
- 同一 threadId 在 Bridge 内只允许一个 pilot attachment。
- Bridge 启动 RPC 与 `thread/started`/turn 事件建立精确关联，不能按标题归因。
- 旧 generation 的事件不能覆盖当前状态。
- Desktop 发起的 active turn 在 Mobile/Bridge 投影中不得显示成 idle 或第三套“处理中”。

#### 1.5 Pilot 拓扑诊断

必须同时证明：

- daemon socket 存在并通过 initialize；
- Desktop 不再拥有私有 stdio app-server；
- Desktop 与候选 Bridge 都连接同一 socket/daemon boot identity；
- 两边 `CODEX_HOME`、账号/profile、source 一致；
- `~/.codex/ipc/ipc.sock` 没有被误认成 daemon socket；
- 官方 Remote Control 没有另启第二个远程宿主；
- Bridge reload 不改变 daemon PID。

### 阶段 2：Bridge ↔ Desktop 真实联动试验（强制停点）

#### 2.1 自动预检

先在隔离端口、隔离 Home 和测试 daemon 完成：

- 两个初始化客户端连接同一 daemon。
- Bridge `thread/start` 产生唯一 threadId 和 `thread/started`。
- 第二客户端无需重启即可收到该线程和状态。
- 标题由空/占位更新为正式值时不产生重复 thread。
- `thread/resume(excludeTurns:true)` 不覆盖 model、effort、权限和 sandbox。
- active thread 不被误判 idle。
- Bridge 重启后 daemon PID 和 canary turn 保持，Bridge 能重新 initialize/resume/reconcile。
- private mode、Claude 和旧 Mobile 投影不回归。
- 候选失败时不影响生产 8765、生产 Home 或真实历史。

自动预检通过后，才准备真实用户试验。真实切换必须由独立于 Bridge 的本机 updater 完成，不能让当前 Bridge 会话执行会切断自身的 unload 后续步骤。

#### 2.2 真实隔离环境准备

Pilot 使用隔离 `CODEX_HOME` 和隔离 Bridge 数据目录，避免 production private Bridge 与 shared daemon 同时写同一来源：

1. 建立新鲜、短时有效、绑定候选 HEAD/runtime/daemon/临时 Desktop 重启和试验路由的授权。
2. 记录当前 Desktop、生产 Bridge 8765、private app-server、GUI 环境键及其“原值或原本不存在”状态；当前有重要 turn 时不退出 Desktop。
3. 创建独立测试 `CODEX_HOME`、canary project 和测试身份；认证材料只以安全引用/受控复制提供，不写入日志或 Git。
4. candidate Bridge 固定使用 18765 或另一个明确隔离端口，并使用独立 state dir、`bridgeInstanceId`、binding/queue、凭据和日志；关闭生产 push、mDNS、OTA 与 Cloud 写入。
5. 生产 Bridge 8765、runtime、LaunchAgent、真实 `CODEX_HOME` 和手机正常数据保持不动；若任何步骤必须暂停 8765，则该步骤不再属于普通隔离 pilot，需另获明确的短时生产影响授权。
6. 完整退出 Desktop，确认其原 private stdio 子进程退出。
7. 启动测试 daemon，绑定隔离 Home。
8. 在 GUI launchd domain 设置临时 Desktop 门禁及隔离 Home，以 shared daemon 模式打开 Desktop，并证明没有静默回退 stdio。
9. 启动 candidate Bridge，验证 Desktop/candidate 使用同一测试 daemon、同一隔离 Home/source；production 8765 不属于该 authority。
10. L0 用本机 candidate 客户端完成协议预检；L1 再让物理手机通过独立 candidate endpoint 完成真实链路。L1 是 pilot 通过的必要证据，不以本机 curl/WS 替代，也不需要新 IPA。
11. 不主动修改 Mullvad。Tailscale/Tailnet 临时映射若必需，须单独授权并在试验后撤销。

#### 2.3 我交给用户的逐步试验操作

到达本阶段后，我必须暂停自动实施，并按当时真实 UI 给用户提供“点哪里、输入什么、看到什么”的操作说明。至少完成：

1. 保持 Codex Desktop 打开且侧栏可见，停留在线程 A，不重启它；记录当前选中线程和前台应用。
2. 通过 candidate Bridge 新建唯一标题的 canary 会话 B；可优先由当前手机连接独立 candidate endpoint，也可先由本机 Bridge 测试客户端触发。
3. 先不要在 Desktop 手动刷新、搜索、置顶、resume 或重启。
4. 观察 B 是否自动出现在目标项目侧栏；正常目标 5 秒内，硬观察上限 10 秒，并记录真实耗时。
5. 检查正式标题更新后是否仍是同一张卡，且没有同名串线；点击它后 Desktop 必须打开原 threadId，不能 fork/start 出第二个 ID。
6. 确认默认 `sidebarOnly` 不抢 Desktop 焦点：线程 A 仍被选中，Desktop 未被拉到前台。
7. 从手机在该会话发起一轮，Desktop 打开该 thread 后应看到相同 `threadId`、`turnId`、内容、运行状态和最终结果。
8. Desktop 已经打开该 thread 时，再从手机发起一轮，双方必须观察同一 canonical `turnId`，并验证实时增量而不是退出重进后才补齐。
9. 从 Desktop 发起一轮，手机应看到同一 `turnId`、Working、Need You、工具、审批和最终结果。
10. 从 Bridge 继续一个 Desktop 已知的 durable thread，确认原侧栏条目不消失、不重复；打开后读取同一 canonical 最新内容。
11. 安全 canary turn 运行时只重启 candidate Bridge，确认 daemon/Desktop 不重启、turn 不终止、Bridge 恢复同一 activeTurnId，且没有重复消息或工具。
12. 单独让 canary 等待 approval/question，再重启 candidate Bridge；验证 daemon 以同一 canonical request ID 重放、Mobile 卡片恢复、任一端解决后只产生一个终态且广播 resolved。
13. 若安全导航 capability 可用，再切换 `autoOpen`，由 Bridge 测试客户端携带 `presentationIntent=applyMachinePolicy` 和幂等 request ID；验证每个显式意图最多打开一次，后台状态刷新不抢焦点。

另外必须单独测试两个发现边界：

- Desktop 离线时由 Bridge 创建 `T2`，随后启动 Desktop；Desktop 启动目录同步应通过 `thread/list` 发现 `T2`。
- Desktop 已运行但从未知道 `T3`，Bridge 只执行 `thread/resume(T3)`；若侧栏不出现，记录为真实协议/产品缺口。不得伪造 `thread/started`、重复创建 thread、按标题合并或靠重启冒充通过。该缺口是否阻断完整目标，由用户在停点报告中决定。

#### 2.4 侧栏验收必须分层

不能只用一层证据宣称成功。必须分别确认：

- thread 数据存在且未归档；
- 能按 threadId 读取；
- `thread/started`/status 通知到达 Desktop；
- Desktop conversation store 已 upsert；
- 标题正确；
- cwd/project identity 正确；
- project assignment 与 sidebar order 正确；
- 用户在真实目标项目侧栏能看到；
- 是否自动打开符合当前策略。

如果底层 thread 可读但侧栏不可见，先定位是事件、store、项目 assignment 还是 sidebar order；不允许靠重启 Desktop、临时置顶或按标题复制会话冒充修复。

失败定位按以下顺序进行：

| 现象 | 优先定位 |
|---|---|
| 第三观察连接也收不到 `thread/started` | daemon 版本、目标二进制合同、initialize/notification opt-out、是否实际连接同一 daemon |
| 观察连接收到、Desktop 收不到 | Desktop daemon 门禁静默回退 stdio、socket/CODEX_HOME/CLI/profile 不一致 |
| Desktop 收到但 store 不 upsert | ephemeral/prewarmed/subagent/source filter、sync gate 或 Desktop 版本漂移 |
| store upsert 但侧栏无条目 | archive、project assignment、sidebar order、workspace/sourceKind/filter 和 renderer selector |
| 手工刷新或重启后才出现 | Desktop catalog invalidation 缺口；不能算 shared runtime 自动联动通过 |
| 续用后出现两个条目 | threadId/source identity 映射错误，禁止按标题或 cwd 合并 |
| 点击条目后生成新 ID | Desktop 走了 start/fork 而非 resume，或来源身份不一致 |
| 侧栏有条目但打开后无实时 turn | Desktop 未成功 subscribe/resume，检查 active snapshot 和 attachment |
| Bridge 重启后审批消失 | 目标 daemon pending-request replay 合同不成立，或 Bridge reconcile 前错误清理/响应 |
| 试验影响生产 8765 | 隔离失败，立即完整回滚，不继续产品诊断 |

#### 2.5 试验通过标准

- 切换完成后，Bridge 新建/继续会话无需重启 Desktop 即可在正确项目侧栏出现或更新。
- Desktop 与手机使用同一个 threadId，不按标题关联。
- 不产生重复卡片、重复 turn、重复工具或重复审批。
- 已打开 thread 能看到实时状态和增量；未打开 thread 至少更新侧栏状态，打开后读取最新权威快照。
- model、reasoning effort、permissions 和 sandbox 不被 observer attach 降级。
- Bridge 重启不终止 daemon 执行中的 turn，pending approval/question 能按合同重放并 exactly-once 解决。
- 默认不抢焦点；autoOpen 单独记录为 passed 或 capability-gap。若为 gap，只能进入用户决策停点，不能进入全量完成。
- 所有失败均有 threadId、daemon boot identity、connection generation 和事件链证据。

#### 2.6 强制暂停规则

- 用户没有明确确认联动试验结果和已发现能力边界前，不进入阶段 3 及以后。
- 试验失败时，只修阶段 1–2 的共享闭环并重复试验。
- 不以自动测试或静态 Desktop 代码代替用户看到的侧栏行为。
- 不因 pilot 成功就发布 stable、部署 Cloud、发 OTA 或清理回滚 runtime。
- 若 `autoOpen` 没有安全能力，只报告能力缺口；pilot 可以在此停点，但不得宣称全量完成。后续只有真实实现并验收 `autoOpen`，或用户明确缩小需求，才能越过全量完成门禁。

#### 2.7 试验后完整恢复现场

无论成功或失败，默认先恢复原现场再等待用户确认；顺序必须避免短暂双 authority：

1. candidate 停止接受 mutation，settle RPC；无法确认结果的 mutation 写入试验 operation ledger，不重发。
2. 停止 candidate Bridge并退出 shared Desktop。
3. 停止测试 daemon，确认其 PID、control socket 和测试 authority 消失；daemon 无法报告 idle 时不得启动同一测试 Home 的 private authority，采用有界等待或由用户明确接受中断后强停。
4. 按试验前记录精确恢复每个 GUI 环境键：原本不存在才 unset，原本有值则恢复原值。
5. 以普通方式重开 Desktop，验证原 `CODEX_HOME` 与 private stdio 子进程恢复。
6. 验证生产 Bridge 8765 的 LaunchAgent、PID、监听、health、version 和手机连接始终未被替换。
7. 撤销 candidate 临时凭据、state dir、路由和映射；可重建测试数据按证据门禁清理。
8. 保留脱敏 trace、threadId/turnId/requestId、截图、二进制 hash 和回滚记录。

用户若当场明确要求继续观察 shared pilot，可以暂留，但该授权只覆盖试验运行，不等于全量实施或发布。

### 阶段 3：用户确认后，吸收新增 upstream 并完成 Transport

用户确认阶段 2 后：

1. 重新 fetch 最新 `upstream/main`。
2. 若从 pilot 到现在 upstream 又有新提交，继续在 feature worktree 语义合入，不用本地整文件覆盖上游。
3. 重新生成目标 app-server schema。
4. 只要 Codex/Desktop/Bridge/shared-runtime 相关代码或目标二进制有任何变化，就完整重跑阶段 1–2，并再次停下让用户做最小侧栏复验；不能只在“看起来破坏联动”时才复验。
5. 安装并验证独立 keeper 与正式 Desktop 启动环境，但仍不切生产默认。
6. 补齐完整 Transport 与重连状态机。

Transport 状态保持：

```text
disconnected
→ connecting
→ connected
→ disconnected(retryable)
→ fatal / closedByOwner
```

完整约束：

- 不重放任意已发 JSON-RPC。
- 未知结果的 `turn/start`、steer、approval、settings 标为 `outcomeUnknown`。
- overload、连接建立和明确幂等的读取才允许退避重试。
- socket 被替换、daemon boot identity 改变或 generation 变化时，失效旧 turn/approval/control lease。
- 新连接重新 initialize，再对精确 thread 做 resume/reconcile。
- 重连前后的 frame、RPC 和 server request 均由 generation fence 隔离。
- backpressure、frame、内存队列和 reconnect 数量保持有界。

### 阶段 4：线程接管与中央协调

重点修改：

- `packages/bridge/src/codex-process.ts`
- `session.ts`
- `websocket.ts`
- 新增 `codex-shared-runtime-coordinator.ts`

`CodexProcess` 增加：

```text
connecting
→ initializing
→ attaching
→ reconciling
→ idle | activeAdopted | waitingApproval
→ reconnecting
```

`thread/resume` 的共享 attach 请求只能包含：

```text
threadId
excludeTurns: true
initialTurnsPage: bounded summary page
```

禁止 attach 时发送 model、effort、sandbox、approval policy、writable roots 或 profile，以免打开手机就把 Desktop 的 ultra/high、权限或模型覆盖掉。

resume 后必须：

- 解析真实 `thread.status`；
- 合并 active turn；
- 恢复 `activeTurnId`；
- 接收 pending approval/question 重放；
- 读取权威 settings；
- active 时禁止发 `input_ready`；
- 只有 idle、无 attention 且 reconcile 完成时才设 `writable`。

Coordinator 使用：

- 一条 control connection 接收全局状态和读取目录。
- 每个 active、Need You、自动批准启用或手机当前聚焦线程建立一条独立 attachment。
- 所有特殊状态线程不设数量上限。
- 普通 idle 热 attachment 使用最多 8 条、5 分钟 LRU。
- 最近会话缓存不等于 live attachment，不 auto-resume 全目录。
- 所有 `new CodexProcess` / `createStandaloneCodexProcess` 调用点必须分类为：
  - shared control read；
  - per-thread attachment；
  - legacy private。
- 不允许存在未登记的第四条创建路径。

### 阶段 5：发送、引导、审批、设置和持久队列

新增：

- `codex-action-broker.ts`
- `codex-runtime-binding-store.ts`

队列仍保持每线程一个待发送任务，但持久化：

```text
codexSourceId
threadId
project/resume identity
clientMessageId
payload digest
durable attachment references
stage
last canonical revision
generation
createdAt/updatedAt
```

规则：

- 图片和附件不能只保存临时路径或内联大块 base64；必须转为 durable artifact reference 后才允许进入重启安全队列。
- journal 损坏时保留原文件并进入 degraded，禁止用空文件覆盖。
- 只恢复有 queue、pending attention、明确 attachment 或用户 pinned 的线程。
- 无活动证据的 binding 最多保留 7 天，总恢复上限 512，journal 总量必须有界。

新 turn：

1. 获取 per-thread mutex。
2. 校验 generation、source、controlState。
3. 再读一次权威 active state。
4. active 时：
   - 明确“引导”才调用 `turn/steer(expectedTurnId)`；
   - 普通输入进入持久队列。
5. idle 且发布门禁允许时调用 `turn/start`。
6. 响应丢失则标记 `outcomeUnknown`，先查 active turn/权威历史，不能立即重发。
7. 检测到同一线程同时出现两个 active turn ID 时：
   - 立即冻结该线程全部 mutation；
   - 不自动 interrupt 任一 turn；
   - 显示冲突诊断并等待用户处理。

审批：

- Bridge 维护 `source + thread + requestId + generation` 的活动台账。
- 聊天气泡、自动批准和通知长按使用同一个 opaque approval ID。
- Desktop 与 Bridge 谁先响应谁生效。
- 后到响应映射为 `alreadyResolved`，不显示运行错误。
- `serverRequest/resolved` 清理所有端的卡片。
- 共享 daemon 中自动批准可在手机断线时工作。
- 未知未来 server request 不立即回 `-32601` 抢占全局 callback；标记 unsupported/degraded，等待其他客户端处理或上游超时。
- 目标版本启用前必须合同测试 Bridge 已支持的全部 request method。

设置：

- `thread/settings/updated` 是权威状态。
- Mobile 写设置携带 generation 和 Bridge-local settings revision。
- Bridge 串行发送，随后以通知/返回值重新读取 canonical settings。
- unknown 不使用新会话默认值覆盖。
- Desktop 并发修改时显示冲突后的真实值，不伪造“保存成功”。

外部时钟：

- 若 `[features.current_time_reminder] clock_source="external"`，共享模式禁止上线；官方当前实现要求线程恰好只有一个 subscriber，多客户端会失败。[官方 current-time 实现](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/current_time.rs)

### 阶段 6：同步协议、Mobile 与通知

Bridge 重点修改：

- `conversation-sync-v2.ts`
- `conversation-sync-v2-protocol.ts`
- `auto-approval.ts`
- `background-notification-projector.ts`
- `codex-desktop-continuity.ts`

Mobile 重点修改：

- `conversation_sync_v2_protocol_slot.dart`
- `bridge_service.dart`
- `conversation_content_sync_service.dart`
- `chat_session_cubit.dart`
- `session_list_cubit.dart`
- `session_visual_status.dart`

Mobile 保留现有：

```text
Bridge identity
→ conversation-sync-v2
→ staging/SQLite
→ commit 后 ACK
→ repository/Cubit/UI
```

不改为每个线程单独连接，也不把所有 durable `RecentSession` 伪装成 `SessionInfo`。

行为修改：

- 手机打开会话仍先渲染 SQLite，不因为 daemon attach 再显示整页加载。
- `source` 与 `executionHost` 分离，解决电脑图标、Bridge 图标和第三套“处理中”互相跳变。
- `controlState` 决定发送/引导/审批按钮，不再依赖 `externalDesktopTurnActive` 特判。
- Working、Need You、error 和未读继续走复合状态。
- 状态变化只重建对应卡片；除既定重要/未读分组外，不重排整个列表。
- daemon 事件先转成统一 `ServerMessage`，再进入 v2、会话 UI 和 notification projector。
- 后台 notification-only 继续不传正文、不写完整 timeline。
- `desktopPresentationPolicy` 按已认证 `bridgeInstanceId` 保存；旧 Bridge 或能力缺失时只显示 sidebar-only 兼容行为。
- `desktopPresentationPolicy` 是机器级 canonical setting，不写进每线程 `status_json`；Bridge 下发 `supportedPolicies/configuredPolicy/effectivePolicy/revision`，Mobile setter 携带 `requestId + expectedRevision`，失败后回滚到服务端 canonical 值。
- 设置入口位于当前 Mac/Bridge 的设置区域，多台 Mac 分别保存；Claude、private 模式、旧 Bridge 或 Desktop 不支持时隐藏/禁用并说明原因。
- `sidebarOnly` 文案为“仅在 Codex Desktop 侧栏显示（默认）”；`autoOpen` 文案明确提示可能切换 Desktop 当前会话。
- 只有显式用户新建、继续或“在 Desktop 打开”携带 presentation intent；内部 attach/reconcile、LRU 预热、审批恢复、queue drain、标题更新和 Bridge reload 永远不触发 auto-open。
- 本轮不修改 Swift、entitlement、通知 category、method channel 或原生插件。
- status JSON 已存于 SQLite 的 `status_json`，新增可选字段不需要 schema migration。
- Dart-only 部分优先走兼容 base 的 owner OTA；若没有可用 Shorebird base，才构建新 IPA。

### 阶段 7：收束 Desktop continuity

共享 daemon 验收后：

- app-server events 是唯一实时主通道。
- JSONL continuity 只在 private/legacy 模式启用。
- daemon 模式下不得同时把 JSONL watcher 与 app-server delta 合并进同一线程。
- JSONL 只允许用于离线诊断或明确的冷 gap 审计，不能参与实时 UI 排序。
- `replaceCodexSessionAfterExternalTurn`、history-dirty 重水化和“外部 turn 不可引导”分支在 shared capability 下停用。
- legacy 代码先 capability-gated 保留，经过两个兼容发布窗口后再决定删除。

官方当前没有公开 subscriber-presence API，`thread/loaded/list` 只能证明线程仍在内存，不能证明 Desktop 窗口仍附着。因此 UI 不显示未经证明的“Desktop 在线”；只显示当前 turn 的已确认发起来源。[官方相关缺口 #35676](https://github.com/openai/codex/issues/35676)

## 四、并发门禁、测试与性能审计

### 1. 已确定的分阶段策略

采用用户确认的“先联动试验、再分阶段放开”：

1. Pilot 只验证共享目录、Desktop 侧栏自动发现、实时状态、有限增量、受控 canary 新 turn 和 Bridge 重启连续性。
2. Pilot 的 `turn/start` 只能在单 actor canary 门禁下使用，不代表生产 writable。
3. 用户确认前的 pilot 已完成 canary approval/question replay；用户确认后再扩展到全部审批类型、异常、并发 first-resolver 和 `turn/steer(expectedTurnId)` 验证。
4. 生产新 turn 发送默认保持关闭。
5. 只有目标 Codex 精确二进制通过双客户端竞态门禁，才把 `controlState` 从 `readOnly/steerable` 提升为 `writable`。
6. 任何失败都保持当前 compat.11/private 生产回滚能力，不做半套 shared writable 切换。

原因是官方仍有同一线程出现两个同时活动 turn 的公开问题，且会真的并发执行工具。[openai/codex#34767](https://github.com/openai/codex/issues/34767)

### 2. 并发认证门禁

必须同时通过：

- Fake daemon：至少 10,000 组随机响应、断线、迟到和重复事件交错。
- 精确生产 Codex 二进制：
  - 使用隔离 `CODEX_HOME`；
  - 两个初始化客户端；
  - 本地测试 MCP hold tool 保持第一 turn 活动；
  - 至少 50 次随机 0–200 ms 双客户端 `turn/start` 竞态；
  - JSONL、状态和事件流中不得出现重叠 active turn；
  - 再进行至少 60 分钟 send/queue/steer/reconnect soak。
- 任一重叠、重复工具执行或无法解释的 activeTurnId 变化均判定门禁失败。

### 3. 自动验证

Bridge：

- 四种旧 mode 与 daemon mode。
- 未知 mode fail closed。
- UDS Upgrade、socket replacement、权限、分帧、大帧。
- `-32001` 退避。
- active resume/adoption。
- thread-scoped server request 校验。
- approval replay、first responder、resolved。
- Bridge restart 时 streaming/approval/question/queue/settings/steer。
- queue journal crash-point 与 corrupt-file。
- Claude 隔离。
- 旧 Mobile 投影。
- Bridge 新建 thread 时 Desktop peer 收到 `thread/started`。
- title/project metadata 更新不产生重复 thread。
- Desktop 已知 thread 的 resume 不产生第二个条目。
- Desktop 未运行时创建的 thread 能在下次 `thread/list` 中发现。
- Desktop 已运行但未知 thread 的 resume 行为被记录并按真实能力判定，不伪造创建事件。

Desktop 真实 UI：

- 一次性 shared-daemon 启动后，不再靠重启发现 Bridge 新 thread。
- 真实项目侧栏可见，不只验证 thread DB/store。
- sidebarOnly 不抢焦点。
- 已打开 thread 接收实时状态和内容。
- 未打开 thread 状态更新，打开后读取 canonical 最新快照。
- autoOpen capability 存在时只响应显式操作。
- 重连、重复事件、后台 attach、reconcile、queue drain 和标题同步不触发 auto-open。
- presentation 失败不回滚或重复 thread/turn mutation。

Mobile：

- 新旧 capability decoder。
- idle 无 Ready。
- executionHost 两种图标且不跳变。
- controlState 按钮门禁。
- queue 双勾/普通单勾。
- detached preview 不 resume。
- daemon unavailable 与 Bridge disconnected 的不同提示。
- list 不因 status heartbeat 抖动排序。
- SQLite generation、gap、reset、迟到帧。
- 后台审批/完成通知。
- old Bridge fallback。
- desktop presentation 设置按 `bridgeInstanceId` 隔离，pending 时禁止重复点击，ACK 失败恢复 canonical 值。
- 新 Bridge + 旧 Mobile 默认 sidebar-only；新 Mobile + 旧 Bridge 隐藏/禁用设置；不支持 auto-open 的 Desktop 返回结构化 unsupported，不伪装保存成功。

完整验证：

- Bridge 全量 test/build/native helper。
- Functions typecheck/test/build；未修改 Cloud 时不部署。
- Flutter 全量测试和 analyze。
- iOS Simulator Debug/Release。
- RunnerTests。
- HTML、JSON、Quick Look、文件安全、通知、后台和 Face ID 编译回归。
- `git diff --check`。
- 新旧 Mobile × 新旧 Bridge × private/daemon × Claude/Codex 兼容矩阵。

### 4. 性能目标

保留现有 v2 目标，并新增：

- 100 个未变化会话：零正文读取。
- daemon 控制连接固定 1 条。
- thread connections ≤ control + 全部特殊线程 + 当前聚焦线程 + 8 条 idle LRU。
- daemon 模式下不运行 750 ms/10 s JSONL live watcher。
- Desktop event 到 Mobile SQLite commit：正常局域网 p95 ≤ 500 ms。
- Bridge warm reload 后恢复 active thread：p95 ≤ 2 秒。
- Bridge `thread/start` 到 Desktop 侧栏可见：试验记录真实值，正常目标 p95 ≤ 2 秒。
- 同一 event/item/turn 在 Bridge 与 Mobile 中最多提交一次。
- Bridge reload 不导致模型输出、工具或审批重复。
- 空闲 CPU 不高于 private 基线；RSS 与连接数不随目录总量线性增长。
- UI 仅重建变化卡片和可见消息窗口。
- 动画离屏或状态结束后无持续 ticker。

功能完成后单独执行：

- CPU、RSS、event loop、UDS 帧数、队列和 backpressure 扫描。
- SQLite query plan、事务、staging、缓存增长和打开延迟扫描。
- 列表、折叠、流式 delta、悬浮窗和动画重建扫描。
- Provider → Bridge → protocol → SQLite → reducer → UI 全链审计。
- Desktop thread store → project assignment → sidebar order → visible card 链路审计。
- 安全审计：socket、诊断、token、路径、prompt、approval payload。
- P0/P1 必须为零；P2 必须修复或给出明确非阻断证据。

## 五、部署、温和切换与回滚

### 1. Pilot 临时切换

Pilot 全程使用隔离 Home、state、身份和端口；只临时重启 Desktop 进入测试 Home，不替换生产 8765：

1. 候选 Bridge、daemon 和 Desktop launcher 均已自动验证。
2. 使用独立 updater，不从即将被停止或隔离的 Bridge 内执行自重载。
3. 建立新鲜试验授权；普通 worker、旧委托和发布会话不能自行触发。
4. 当前 Desktop 的 active turn、attention 和临时会话清空；production Bridge 的真实 Home/8765 不加入测试 authority。
5. 保存 GUI 环境每个键的原值/不存在状态、Desktop 普通启动方式和日志回滚点。
6. candidate 使用隔离 Home、Bridge state、instance ID、凭据、日志和端口，不覆盖旧 runtime。
7. 一次性完整退出 Desktop，启动测试 daemon、shared Desktop 和 candidate Bridge。
8. L0 先做本机 candidate Bridge；随后必须做 L1 物理手机独立 candidate endpoint，不能把本机 curl/WS 当成真实链路通过。
9. 用户完成阶段 2 试验。
10. 无论成功失败，按“退出 shared 客户端 → 停 daemon并确认 authority 消失 → 精确恢复 GUI 环境 → 重开 private Desktop”的顺序恢复；生产 8765 只复核未被替换。
11. 成功也先停在用户确认点，不自动转生产、合并、OTA 或 stable。

### 2. 首次正式生产切换

用户确认 pilot、完整实施和审计通过后，首次从 private 转 daemon 仍必须完整 drain，因为已有私有 app-server 无法迁移：

1. 构建正式候选，但不动生产。
2. 在隔离端口、隔离 CODEX_HOME 和测试 daemon 完成全部合同测试。
3. 建立新鲜、带过期时间的 Bridge/daemon 激活授权，包含完整 HEAD、runtime SHA、daemon 版本、目标 LaunchAgent 和回滚点；不得在同一授权中夹带 owner OTA。
4. Bridge 进入 maintenance，停止接受新 mutation。
5. 完整 drain Bridge/Desktop 的 active turn、approval、question、server request、in-flight RPC、side chat、subagent、review、ephemeral/private session；队列、binding、receipt 与 `outcomeUnknown` operation ledger 全部落盘。无法迁移的 ephemeral 状态必须完成或由用户明确接受中断。
6. 由独立 host updater 完全退出 Desktop、停止旧 Bridge，并确认旧 private authority 消失。
7. 安装并启动 standalone daemon。
8. 通过受控 Desktop launcher，或登录后执行 GUI-domain `setenv` 的一次性 job，固化已验证环境；普通 LaunchAgent 自己的 `EnvironmentVariables` 不算注入 ChatGPT。
9. 启动 daemon-mode Bridge。
10. 重新打开 Desktop并证明没有静默回退 stdio。
11. 验证只有一个 app-server authority，Desktop/Bridge 都连接同一 UDS。
12. 完成双端 canary、Mobile 重连、状态、发送、审批、通知和 gap 验收后退出 maintenance。

### 3. 后续 Bridge 温和更新

daemon 建立后，只有新旧 Bridge 都支持 daemon、binding journal/schema 向后兼容，且本窗口不改变 daemon/CLI/Desktop 时，才允许温和更新：

1. 新 Bridge 先在 18765 以 observer 身份接入同一 daemon，不能取得写权。
2. 旧 Bridge 保持唯一 writer generation；手机验证 candidate 的只读诊断和同步。
3. 旧 Bridge 停止接收新 mutation，等待 connection-affine 请求解决。
4. settle RPC，并把 `outcomeUnknown`、queue、binding、receipt 写入持久 operation ledger；新 Bridge reconcile 前继续禁止 mutation。
5. 18765 candidate 始终保持 observer，绝不接收 writer generation。
6. 独立 updater 停止旧 8765 listener，使用新 `BRIDGE_CLI_ENTRY` 启动精确的新 production 8765 instance，但先保持 observer/reconciling；不从旧 Bridge 自己执行重载。
7. 新 production 8765 initialize、resume、reconcile、补 gap并验证 ledger 后，以 exact instance ID 做一次原子 CAS，把 writer generation 从旧 production 转给新 production；任一时刻只能有一个 writable Bridge。
8. 恢复 mutation，复核 18765 candidate 仍为 observer，然后停止 candidate。

合格的 active turn 由 daemon 执行，不随 Bridge 重启终止；但只有不存在 connection-affine approval、question、server request、external current-time/attestation 或未闭合 reconcile gap 时才允许温和重启。存在这些条件时先等待解决，不能用“daemon 还活着”替代控制面连续性。

### 4. daemon 更新

daemon/standalone 更新仍要求：

- active turn 为零；
- 无 pending approval/question；
- 队列持久化；
- 安装精确新版本；
- 显式 `daemon restart`；
- 重新执行 schema、双客户端和 Desktop hidden-gate 验收。

不得启用无 drain 的自动 updater。

### 5. 回滚

- 新 Bridge 失败、daemon 健康：
  - 优先回滚到上一版 daemon-capable Bridge，不停止 daemon。

- 首版 daemon 发布只能回滚 compat.11/private：
  - 完整停止 mutation；
  - 等待 daemon turn idle；
  - inhibit/卸载 keeper，防止 daemon 被自动拉起；
  - 退出 shared Desktop/Bridge；
  - 停止 daemon并确认 PID/socket/authority 消失；
  - 按原值精确恢复 Desktop GUI 环境；
  - 恢复 compat.11 LaunchAgent并重启 private Desktop/Bridge。

  daemon 无法报告 idle 时不得直接启动同一 Home 的 private authority；先有界等待并诊断。只有用户明确接受正在运行 turn/ephemeral 状态可能中断时，独立 updater 才可强停 daemon，且仍须先确认 authority 消失再启动 private。

- daemon 版本失败：
  - active turn 为零后把 standalone `current` 指回上一版本；
  - `daemon restart`；
  - 复核 PID、socket、initialize 和版本。

最终部署由既定发布任务 `019f8e9d-2490-79c0-817c-87e3eb93ea2f` 执行，但只有在真实试验、用户确认、全量实现验证和第二次生产授权之后才能联系它。授权必须短时、单次、不可转授权，并绑定 issuer、authorization nonce/generation、createdAt、expiresAt、完整 HEAD、干净 worktree、artifact/runtime hash、daemon 版本/hash/socket/CODEX_HOME、Bridge label/path/端口、writer generation、允许动作、目标渠道/设备和回滚件。Bridge/daemon 激活与 owner OTA 分别授权；发布任务在每个不可逆动作前重新读取并消费授权，HEAD 漂移、过期、新用户指令或任务重启后都不得自动续跑。旧委托、子 Agent或普通完成回报不能触发服务切换。

## 六、提交、版本与完成门禁

### 1. 提交顺序

Pilot 阶段：

1. `集成：在 feature 线语义接入最新官方 CC Pocket`
2. `Bridge实验：增加 daemon 严格配置和 UDS transport`
3. `Bridge实验：增加单线程 attach、active adoption 和诊断`
4. `Desktop实验：增加可回滚 shared-daemon 启动入口`
5. `测试：验证 Desktop 全局 thread 发现与同线程续用`
6. `记录：保存真实联动、能力限制和完整回滚证据`

随后设置硬门：`STOP — 未经用户读取真实联动报告并明确确认，不得继续。`

用户确认后：

7. `集成：吸收 pilot 后新增的官方更新并复验`
8. `Bridge：完成线程 attach、active turn 接管与重连`
9. `Bridge：增加 action broker、持久队列和回执`
10. `Bridge：统一审批、设置与 Goal 权威路由`
11. `协议：增加共享运行时状态与诊断能力`
12. `协议：增加 Desktop sidebar/auto-open 独立能力与机器级设置`
13. `Mobile：统一主机状态、控制门禁和 Desktop 展示设置`
14. `通知：接入 daemon attention/result 投影`
15. `兼容：收束 Desktop continuity 为 private fallback`
16. `运维：完成 readiness、温和切换和回滚`
17. `审计：记录合同、性能、安全、侧栏联动和兼容结果`

每个提交按行为拆分、可独立审查和回滚；pilot feature flag、正式 shared capability 和生产默认切换不得混在同一提交。

### 2. 版本规则

- 若上游仍为 Bridge 1.69.6，候选预计从 `compat.12` 起；实施时按现场最高 compat 单调递增。
- Mobile 当前记录基线为 `1.111.1+211`，实施时重新核对最高 build。
- Pilot 若复用现有 Mobile 协议，不构建新 IPA。
- Dart-only 且存在精确 Shorebird base 时优先 owner OTA，不改 build。
- 若必须构建 IPA，build 至少为当前最高值加一；不得为凑 OTA 偷改 native 边界。
- 不发布 stable，除非用户后续明确授权。

### 3. Pilot 停点完成标准

- 独立 feature worktree/branch 和精确提交可审查，未合入 integration。
- 新建、已知 thread 续用、Desktop 离线后发现、Desktop 在线但未知 thread resume 四种行为均有真实证据；最后一种失败时完整 sidebar-sync 能力保持未完成。
- 用户看到 Desktop 侧栏行为，并收到 threadId/turnId、拓扑、失败项和回滚状态报告。
- candidate、GUI 临时环境、测试 daemon 和临时路由默认已清理；生产 compat.11/private 恢复并验证。
- 没有源码/服务层试验结果被误写成整个产品已经完成。

### 4. 全量完成标准

- 用户亲自确认 Bridge 新建/继续会话无需重启 Desktop 即在正确项目侧栏出现或更新。
- Desktop 在线但未知旧 thread 的继续路径有受支持、可重复的发现机制并验收，或用户明确缩小该目标。
- `sidebarOnly` 与 `autoOpen` 两种机器策略都已真实实现、配置、持久化和验收；autoOpen 缺失只能作为 pilot 结论，不能进入全量完成，除非用户明确缩小需求。
- Desktop 与 Bridge 真实连接同一 daemon。
- Desktop/手机双向实时状态、增量、steer、审批与发送通过。
- Bridge 活跃 turn 中重启不丢失、不重复。
- 双客户端新 turn 门禁通过。
- P0/P1 为零。
- 全量测试、性能扫描和完整审计通过。
- 生产 Bridge、回滚 runtime、OTA/IPA、物理设备状态分别有证据。
- 分支和 worktree 经过独有提交审计后再清理。
- runtime/缓存/IPA 最终只保留当前版与一个明确回滚版；当前多余旧 runtime 在新候选验证后再精确清理。

全量实现、自动验证、性能扫描和审计完成后设置第二个硬门：

`STOP — 未取得新的 Bridge/daemon 生产激活授权，不得联系发布会话、切换 8765、激活 keeper、发布 OTA/IPA 或改 owner/stable。`

## 七、实施默认假设与不可删减边界

- 该方案是必须遵守的架构与验收纲领，不得在实施时删减核心目标。
- 具体类名、内部算法和文件位置可根据开工时源码调整。
- 每一阶段都必须重新探索真实代码和运行态，不能把本文快照当永久事实。
- 出现偏差时必须记录原假设、源码证据、影响、替代实现和测试。
- Pilot 先验证最小 shared endpoint；它不是半成品生产切换，也不替代后续 action broker。
- Pilot 只改 TypeScript、测试/诊断和临时 macOS 用户级配置，不改 Dart、SQLite、OTA、IPA、Swift 或 entitlement。
- 用户确认后正式产品阶段才允许按计划修改 Dart；第一版仍不修改 Swift/entitlement。
- code 默认模式继续是 private；生产 daemon 通过明确 opt-in 启用。
- ephemeral thread 可跨 Bridge 重启继续存在，但 daemon 重启后仍可能丢失。
- 不使用标题、IP、loaded/idle 或时间戳推断线程身份、Desktop presence 或写入权。
- 不修改 canonical Codex 历史，不把 Mobile SQLite 变成权威写入源。
- `RecentSession` 继续是 durable thread 元数据，`SessionInfo` 继续是 live Bridge runtime；共享 daemon 不得把两者混成同一对象。
- shared daemon 成功后，Bridge 重启连续性、Desktop 侧栏可见性、Mobile 实时内容、审批可操作性仍是不同验收层，必须逐层证明。
- 自动打开 Desktop 是 capability-gated 可选行为；默认且必须实现的是侧栏自动新增/更新而不抢焦点。
- 当前修订只创建隔离 worktree/分支和方案文档，没有修改业务源码、服务、Desktop 配置、Bridge runtime、OTA、IPA 或手机。
